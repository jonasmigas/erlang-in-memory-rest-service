%%%-------------------------------------------------------------------
%%% @doc Cowboy HTTP handler for the KV Store REST API.
%%% Serves the key-value routes and a health check.
%%%-------------------------------------------------------------------
-module(kv_http).
-behaviour(cowboy_handler).

-include_lib("kernel/include/logger.hrl").

%% Supervisor child API
-export([child_spec/0]).
%% Cowboy handler
-export([init/2, terminate/3]).

-define(MAX_BODY_SIZE, 1048576).  %% 1MB
-define(READ_PERIOD, 5000).       %% per chunk
-define(BODY_DEADLINE, 15000).    %% for the whole body

-define(STORE_METHODS, [<<"GET">>, <<"HEAD">>, <<"POST">>, <<"PUT">>, <<"DELETE">>]).
-define(READ_METHODS, [<<"GET">>, <<"HEAD">>]).

-type route() :: store | health | metrics | not_found.

%% ===================================================================
%% Supervisor child API
%% ===================================================================

%% Child spec for the cowboy listener.
%%
%% cowboy:start_clear/3 starts the listener under ranch's own supervisor,
%% which leaves this application's tree owning nothing: a restart would
%% call it again under the same name, get {error, {already_started, _}},
%% and crash-loop past the supervisor's restart intensity -- taking
%% kv_store and every stored key down with it. Embedding ranch's child
%% spec puts the listener in our tree instead, so a restart really does
%% restart it, and application:stop/1 tears it down.
-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    TransOpts = #{
        socket_opts => [{port, port()}],
        connection_type => supervisor
    },
    ProtoOpts = #{
        env => #{dispatch => dispatch()},
        connection_type => supervisor
    },
    %% notice, not info: the kernel logger sits at notice by default and
    %% config/sys.config deliberately leaves it there, so an info line
    %% would be written for nobody. A listener coming up is worth one
    %% line at the level that is actually on.
    ?LOG_NOTICE(#{event => listener_starting, port => port()}),
    ranch:child_spec(?MODULE, ranch_tcp, TransOpts, cowboy_clear, ProtoOpts).

%% The listen port. The default lives in kv_store.app.src, so this
%% carries no literal of its own to drift from it; sys.config, a
%% -kv_store port flag or application:set_env/3 override it, which is
%% how a deployment picks a port and how the tests pick a free one.
%%
%% Matching rather than defaulting is deliberate: child_spec/0 only runs
%% under a started kv_store, so an unset port means the application is
%% broken, and failing there says so instead of quietly binding 8080.
-spec port() -> inet:port_number().
port() ->
    {ok, Port} = application:get_env(kv_store, port),
    Port.

%% ===================================================================
%% Routing
%% ===================================================================

%% Each route names itself, and that name is what the handler dispatches
%% on. Deriving the resource from the request instead -- a path literal,
%% or the absence of the :key binding -- makes the handler disagree with
%% the router: /health has no :key either, so it used to reach the store
%% clauses, and POST /health wrote to the store.
%%
%% The optional segment in "/store/[:key]" already matches /store and
%% /store/ with the binding unset, so no separate "/store" entry is
%% needed for the key-in-the-body form.
-spec dispatch() -> cowboy_router:dispatch_rules().
dispatch() ->
    cowboy_router:compile([
        {'_', [
            {"/store/[:key]", ?MODULE, store},
            {"/health", ?MODULE, health},
            {"/metrics", ?MODULE, metrics},
            %% Last, so it catches only what the routes above did not.
            %% Without it cowboy's router answers an unmatched path
            %% itself, with a bodiless 404 -- the one response in the API
            %% that a client could not decode as JSON.
            {'_', ?MODULE, not_found}
        ]}
    ]).

%% ===================================================================
%% Cowboy HTTP Handler
%% ===================================================================

-spec init(cowboy_req:req(), route()) -> {ok, cowboy_req:req(), route()}.
init(Req0, Route) ->
    %% HEAD must answer wherever GET does. cowboy_req:reply/4 drops the
    %% body for a HEAD request on its own, so the GET clauses serve both
    %% and only the response body differs.
    Method = case cowboy_req:method(Req0) of
                 <<"HEAD">> -> <<"GET">>;
                 Other -> Other
             end,
    Req = handle_request(Route, Method, Req0),
    {ok, Req, Route}.

-spec handle_request(route(), binary(), cowboy_req:req()) -> cowboy_req:req().
handle_request(not_found, _Method, Req) ->
    reply(404, #{error => <<"not_found">>}, Req);

%% Prometheus text, not JSON. It is the format a scraper already speaks,
%% and inventing a JSON shape here would mean writing the exporter too.
%% This is the one endpoint the all-JSON rule in the README does not cover.
handle_request(metrics, <<"GET">>, Req) ->
    Headers = #{<<"content-type">> => <<"text/plain; version=0.0.4">>},
    respond(200, Headers, kv_metrics:render(), Req);
handle_request(metrics, _Method, Req) ->
    method_not_allowed(?READ_METHODS, Req);

handle_request(health, <<"GET">>, Req) ->
    reply(200, #{status => ok, timestamp => os:system_time(second)}, Req);
handle_request(health, _Method, Req) ->
    method_not_allowed(?READ_METHODS, Req);

handle_request(store, <<"GET">>, Req) ->
    %% GET /store/{key}
    with_key(Req, fun(Key) ->
        case call_store(fun() -> kv_store:get(Key) end) of
            {ok, Key, Value} ->
                kv_metrics:store_op(get, hit),
                reply(200, #{key => Key, value => Value}, Req);
            {error, not_found} ->
                kv_metrics:store_op(get, miss),
                reply(404, #{error => <<"key_not_found">>,
                             key => Key}, Req);
            {error, invalid_key} ->
                reply(400, #{error => <<"invalid_key">>}, Req);
            {error, unavailable} ->
                unavailable(Req)
        end
    end);

%% POST /store/{key} with {"value": ...}, or POST /store with the key in
%% the body. /store and /store/ both route here with no :key binding.
handle_request(store, <<"POST">>, Req) ->
    case extract_key(Req) of
        {ok, Key} -> store_with_key(Key, Req);
        {error, missing_key} -> store_from_body(Req);
        {error, invalid_key} -> reply(400, #{error => <<"invalid_key">>}, Req)
    end;

handle_request(store, <<"PUT">>, Req) ->
    %% PUT /store/{key} with JSON body: {"value": "myvalue"}
    case extract_key(Req) of
        {ok, Key} -> store_with_key(Key, Req);
        {error, missing_key} -> reply(400, #{error => <<"key_required_in_path">>}, Req);
        {error, invalid_key} -> reply(400, #{error => <<"invalid_key">>}, Req)
    end;

handle_request(store, <<"DELETE">>, Req) ->
    %% DELETE /store/{key}
    with_key(Req, fun(Key) ->
        case call_store(fun() -> kv_store:delete(Key) end) of
            ok ->
                kv_metrics:store_op(delete, ok),
                reply(204, Req);
            {error, not_found} ->
                kv_metrics:store_op(delete, miss),
                reply(404, #{error => <<"key_not_found">>,
                             key => Key}, Req);
            {error, invalid_key} ->
                reply(400, #{error => <<"invalid_key">>}, Req);
            {error, unavailable} ->
                unavailable(Req)
        end
    end);

handle_request(store, _Method, Req) ->
    method_not_allowed(?STORE_METHODS, Req).

%% ===================================================================
%% Helper functions for storing a value
%% ===================================================================

%% The key comes from the body: {"key": "mykey", "value": "myvalue"}.
%% Owns the body read and every way it can fail, so the two write paths
%% cannot disagree about how a slow, oversized or unparseable body is
%% reported. They had already drifted once: one grew a missing-value
%% answer and the other kept calling that body malformed.
%%
%% Fun sees a decoded JSON object and returns the response. Anything
%% that is not an object -- an array, a bare string, a parse failure --
%% never reaches it and is answered with Expected.
-spec with_json_body(cowboy_req:req(), binary(),
                     fun((map(), cowboy_req:req()) -> cowboy_req:req())) ->
    cowboy_req:req().
with_json_body(Req, Expected, Fun) ->
    case read_body(Req) of
        {ok, Body, Req2} ->
            case decode_json(Body) of
                {ok, Decoded} when is_map(Decoded) ->
                    Fun(Decoded, Req2);
                _ ->
                    reply(400, #{error => <<"invalid_json">>,
                                 message => Expected}, Req2)
            end;
        {error, too_large} ->
            reply(413, #{error => <<"request_too_large">>}, Req);
        {error, timeout} ->
            ?LOG_WARNING(#{event => request_body_timeout,
                           path => cowboy_req:path(Req),
                           deadline_ms => body_deadline()}),
            reply(408, #{error => <<"request_timeout">>}, Req);
        {error, bad_request} ->
            %% read_body/1 collapses anything it cannot classify into this,
            %% so the log line is the only place the reason survives.
            ?LOG_WARNING(#{event => request_body_failed,
                           path => cowboy_req:path(Req)}),
            reply(400, #{error => <<"bad_request">>}, Req)
    end.

%% The one place a key and a value become a stored entry and a response,
%% whichever form the request used to carry them.
%%
%% valid_key/1 runs here even for a path key that extract_key/1 already
%% checked: the rule belongs to writing, not to one route, and paying a
%% second cheap check is better than a second place to forget it.
-spec write(binary(), any(), cowboy_req:req()) -> cowboy_req:req().
write(Key, Value, Req) ->
    case valid_key(Key) of
        false ->
            reply(400, #{error => <<"invalid_key">>}, Req);
        true ->
            case call_store(fun() -> kv_store:set(Key, Value) end) of
                {ok, Outcome} ->
                    kv_metrics:store_op(set, Outcome),
                    stored(Outcome, Key,
                           #{key => Key, value => Value,
                             status => <<"stored">>}, Req);
                {error, invalid_key} ->
                    reply(400, #{error => <<"invalid_key">>}, Req);
                {error, unavailable} ->
                    unavailable(Req)
            end
    end.

%% The key comes from the body: {"key": "mykey", "value": "myvalue"}.
store_from_body(Req) ->
    Expected = <<"Expected {\"key\":\"...\", \"value\":\"...\"}">>,
    with_json_body(Req, Expected,
        fun(#{<<"key">> := Key, <<"value">> := Value}, Req2) when is_binary(Key) ->
                write(Key, Value, Req2);
           (#{<<"key">> := Key}, Req2) when is_binary(Key) ->
                %% Valid JSON, key present, value absent -- say that,
                %% rather than blaming the JSON.
                reply(400, #{error => <<"missing_value">>}, Req2);
           (_, Req2) ->
                %% An object, but not one this route can read: no key, or
                %% a key that is not a string.
                reply(400, #{error => <<"invalid_json">>,
                             message => Expected}, Req2)
        end).

%% The key came from the path, so the body carries only {"value": ...}.
store_with_key(Key, Req) ->
    with_json_body(Req, <<"Expected {\"value\":\"...\"}">>,
        fun(#{<<"value">> := Value}, Req2) ->
                write(Key, Value, Req2);
           (_, Req2) ->
                reply(400, #{error => <<"missing_value">>}, Req2)
        end).

%% ===================================================================
%% Helper functions
%% ===================================================================

%% 201 only when the write actually created the key; RFC 7231 requires
%% 200 or 204 once the target has a representation, so the status alone
%% tells a create from an update.
%%
%% A 201 also carries Location. POST /store puts the resource somewhere
%% the request URI did not name, so without it the client has to rebuild
%% and re-encode the path from a key it just sent.
-spec stored(created | updated, binary(), map(), cowboy_req:req()) ->
    cowboy_req:req().
stored(created, Key, Body, Req) ->
    Headers = maps:put(<<"location">>,
                       <<"/store/", (cow_uri:urlencode(Key))/binary>>,
                       json_headers()),
    respond(201, Headers, jsx:encode(Body), Req);
stored(updated, _Key, Body, Req) ->
    reply(200, Body, Req).

%% kv_store is one gen_server, so a busy or restarting store makes every
%% call exit -- timeout after call_timeout(), or noproc while the
%% supervisor brings it back. Uncaught, that exit leaves cowboy to answer
%% with a bodiless 500, the one response a JSON client cannot read. The
%% listener deliberately survives a store restart (one_for_one), so this
%% window is reachable in normal operation, and 503 is the honest answer.
-spec call_store(fun(() -> Result)) -> Result | {error, unavailable}.
call_store(Fun) ->
    try Fun()
    catch
        exit:_ -> {error, unavailable}
    end.

unavailable(Req) ->
    kv_metrics:store_op(any, unavailable),
    %% The store being unreachable is the one failure an operator has to
    %% know about and the one the response body cannot tell them about,
    %% since the client sees it and they do not.
    ?LOG_WARNING(#{event => store_unavailable,
                   method => cowboy_req:method(Req),
                   path => cowboy_req:path(Req)}),
    reply(503, #{error => <<"store_unavailable">>}, Req).

%% Run Fun with the path key, or answer 400 when the route carried none.
-spec with_key(cowboy_req:req(), fun((binary()) -> cowboy_req:req())) ->
    cowboy_req:req().
with_key(Req, Fun) ->
    case extract_key(Req) of
        {ok, Key} -> Fun(Key);
        {error, missing_key} -> reply(400, #{error => <<"missing_key">>}, Req);
        {error, invalid_key} -> reply(400, #{error => <<"invalid_key">>}, Req)
    end.

-spec extract_key(cowboy_req:req()) ->
    {ok, binary()} | {error, missing_key | invalid_key}.
extract_key(Req) ->
    %% The :key binding is already percent-decoded by cowboy, so a key
    %% written as {"key": "my key"} and read back as /store/my%20key
    %% resolve to the same entry. Splitting the raw path does not.
    case cowboy_req:binding(key, Req, <<>>) of
        <<>> ->
            {error, missing_key};
        Key ->
            case valid_key(Key) of
                true -> {ok, Key};
                false -> {error, invalid_key}
            end
    end.

%% A key has to survive the round trip: the client reads it out of a
%% response and puts it back in a path. Two things break that.
%%
%% Bytes that are not valid UTF-8 cannot be a JSON string, so jsx encodes
%% them as U+FFFD -- /store/%FF and /store/%FE both reported the key as
%% "�", and asking for that back was a third, missing key.
%%
%% Dot segments are removed by cowboy's router before a binding exists,
%% so a key of "." or ".." was writable through the body form and then
%% unreachable and undeletable through the path.
-spec valid_key(binary()) -> boolean().
valid_key(<<>>) -> false;
valid_key(<<".">>) -> false;
valid_key(<<"..">>) -> false;
valid_key(Key) ->
    is_binary(unicode:characters_to_binary(Key, utf8, utf8)).

%% jsx:decode/2 raises on malformed input rather than returning an error,
%% so every call has to be guarded or the handler crashes into a 500.
-spec decode_json(binary()) -> {ok, jsx:json_term()} | {error, invalid_json}.
decode_json(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Decoded -> {ok, Decoded}
    catch
        _:_ -> {error, invalid_json}
    end.

%% cowboy_req:read_body/2 answers {more, ...} for two different reasons:
%% the length it was asked for is available, or the read period expired
%% with the body still incomplete. Matching only {ok, ...} and calling
%% every other outcome too_large told a client on a slow link that its
%% 19-byte body was over the 1MB cap, and dropped the write. Accumulate
%% instead, and separate "over the cap" from "ran out of time".
-spec read_body(cowboy_req:req()) ->
    {ok, binary(), cowboy_req:req()} | {error, too_large | timeout | bad_request}.
read_body(Req) ->
    read_body(Req, <<>>, erlang:monotonic_time(millisecond) + body_deadline()).

read_body(Req, Acc, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left =< 0 ->
            {error, timeout};
        Left ->
            Opts = #{length => ?MAX_BODY_SIZE, period => min(Left, ?READ_PERIOD)},
            try cowboy_req:read_body(Req, Opts) of
                {ok, Data, Req2} ->
                    Body = <<Acc/binary, Data/binary>>,
                    case byte_size(Body) > ?MAX_BODY_SIZE of
                        true -> {error, too_large};
                        false -> {ok, Body, Req2}
                    end;
                {more, Data, Req2} ->
                    Body = <<Acc/binary, Data/binary>>,
                    case byte_size(Body) >= ?MAX_BODY_SIZE of
                        true -> {error, too_large};
                        false -> read_body(Req2, Body, Deadline)
                    end
            catch
                %% cowboy exits with timeout of its own once the period
                %% is well past; anything else is a broken request.
                exit:_ -> {error, timeout};
                _:_ -> {error, bad_request}
            end
    end.

%% How long a whole body may take to arrive. Overridable so a deployment
%% behind a slow link can raise it, and so the test does not have to
%% spend the default waiting.
body_deadline() ->
    application:get_env(kv_store, body_deadline, ?BODY_DEADLINE).

-spec reply(integer(), cowboy_req:req()) -> cowboy_req:req().
reply(StatusCode, Req) ->
    respond(StatusCode, json_headers(), Req).

-spec reply(integer(), binary() | map(), cowboy_req:req()) -> cowboy_req:req().
reply(StatusCode, Body, Req) when is_map(Body) ->
    reply(StatusCode, jsx:encode(Body), Req);
reply(StatusCode, Body, Req) when is_binary(Body) ->
    respond(StatusCode, json_headers(), Body, Req).

%% Every response leaves through here, so the counter cannot drift from
%% what was actually sent -- counting at the call sites instead would mean
%% remembering to, in each of a dozen branches.
respond(Status, Headers, Req) ->
    kv_metrics:request(cowboy_req:method(Req), Status),
    cowboy_req:reply(Status, Headers, Req).

respond(Status, Headers, Body, Req) ->
    kv_metrics:request(cowboy_req:method(Req), Status),
    cowboy_req:reply(Status, Headers, Body, Req).

%% RFC 7231 makes Allow mandatory on a 405, so a client that guessed the
%% method wrong can discover what the resource does support.
-spec method_not_allowed([binary()], cowboy_req:req()) -> cowboy_req:req().
method_not_allowed(Allowed, Req) ->
    Headers = maps:put(<<"allow">>,
                       iolist_to_binary(lists:join(<<", ">>, Allowed)),
                       json_headers()),
    respond(405, Headers,
                     jsx:encode(#{error => <<"method_not_allowed">>}), Req).

json_headers() ->
    #{<<"content-type">> => <<"application/json">>}.

-spec terminate(term(), cowboy_req:req(), any()) -> ok.
terminate(_Reason, _Req, _State) ->
    ok.
