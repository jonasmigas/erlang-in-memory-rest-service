%%%-------------------------------------------------------------------
%%% @doc Cowboy HTTP handler for the KV Store REST API.
%%% Serves the key-value routes and a health check.
%%%-------------------------------------------------------------------
-module(kv_http).
-behaviour(cowboy_handler).

%% Supervisor child API
-export([child_spec/0]).
%% Cowboy handler
-export([init/2, terminate/3]).

-define(DEFAULT_PORT, 8080).
-define(MAX_BODY_SIZE, 1048576).  %% 1MB

-define(STORE_METHODS, [<<"GET">>, <<"HEAD">>, <<"POST">>, <<"PUT">>, <<"DELETE">>]).
-define(HEALTH_METHODS, [<<"GET">>, <<"HEAD">>]).

-type route() :: store | health | not_found.

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
    ranch:child_spec(?MODULE, ranch_tcp, TransOpts, cowboy_clear, ProtoOpts).

%% The listen port, overridable so a deployment (or a test) can pick one
%% that is free. Docker maps the container's port to 18080 on the host.
-spec port() -> inet:port_number().
port() ->
    application:get_env(kv_store, port, ?DEFAULT_PORT).

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

handle_request(health, <<"GET">>, Req) ->
    reply(200, #{status => ok, timestamp => os:system_time(second)}, Req);
handle_request(health, _Method, Req) ->
    method_not_allowed(?HEALTH_METHODS, Req);

handle_request(store, <<"GET">>, Req) ->
    %% GET /store/{key}
    with_key(Req, fun(Key) ->
        case kv_store:get(Key) of
            {ok, Key, Value} ->
                reply(200, #{key => list_to_binary(Key), value => Value}, Req);
            {error, not_found} ->
                reply(404, #{error => <<"key_not_found">>,
                             key => list_to_binary(Key)}, Req);
            {error, invalid_key} ->
                reply(400, #{error => <<"invalid_key">>}, Req)
        end
    end);

%% POST /store/{key} with {"value": ...}, or POST /store with the key in
%% the body. /store and /store/ both route here with no :key binding.
handle_request(store, <<"POST">>, Req) ->
    case extract_key(Req) of
        {ok, Key} -> store_with_key(Key, Req);
        {error, missing_key} -> store_from_body(Req)
    end;

handle_request(store, <<"PUT">>, Req) ->
    %% PUT /store/{key} with JSON body: {"value": "myvalue"}
    case extract_key(Req) of
        {ok, Key} -> store_with_key(Key, Req);
        {error, missing_key} -> reply(400, #{error => <<"key_required_in_path">>}, Req)
    end;

handle_request(store, <<"DELETE">>, Req) ->
    %% DELETE /store/{key}
    with_key(Req, fun(Key) ->
        case kv_store:delete(Key) of
            ok ->
                reply(204, Req);
            {error, not_found} ->
                reply(404, #{error => <<"key_not_found">>,
                             key => list_to_binary(Key)}, Req);
            {error, invalid_key} ->
                reply(400, #{error => <<"invalid_key">>}, Req)
        end
    end);

handle_request(store, _Method, Req) ->
    method_not_allowed(?STORE_METHODS, Req).

%% ===================================================================
%% Helper functions for storing a value
%% ===================================================================

%% The key comes from the body: {"key": "mykey", "value": "myvalue"}.
store_from_body(Req) ->
    case read_body(Req) of
        {ok, Body, Req2} ->
            case decode_json(Body) of
                {ok, #{<<"key">> := Key, <<"value">> := Value}} when is_binary(Key), Key /= <<>> ->
                    KeyStr = binary_to_list(Key),
                    case kv_store:set(KeyStr, Value) of
                        ok ->
                            reply(201, #{key => Key, value => Value,
                                         status => <<"stored">>}, Req2);
                        {error, invalid_key} ->
                            reply(400, #{error => <<"invalid_key">>}, Req2)
                    end;
                {ok, #{<<"key">> := Key}} when is_binary(Key) ->
                    %% Missing value
                    reply(400, #{error => <<"missing_value">>}, Req2);
                _ ->
                    reply(400, #{error => <<"invalid_json">>,
                                 message => <<"Expected {\"key\":\"...\", \"value\":\"...\"}">>}, Req2)
            end;
        {error, too_large} ->
            reply(413, #{error => <<"request_too_large">>}, Req)
    end.

%% The key came from the path, so the body carries only {"value": ...}.
%% extract_key/1 never yields an empty key, so there is no empty-key
%% clause here.
store_with_key(Key, Req) ->
    case read_body(Req) of
        {ok, Body, Req2} ->
            case decode_json(Body) of
                {ok, #{<<"value">> := Value}} ->
                    case kv_store:set(Key, Value) of
                        ok ->
                            reply(201, #{key => list_to_binary(Key), value => Value,
                                         status => <<"stored">>}, Req2);
                        {error, invalid_key} ->
                            reply(400, #{error => <<"invalid_key">>}, Req2)
                    end;
                _ ->
                    reply(400, #{error => <<"invalid_json">>,
                                 message => <<"Expected {\"value\":\"...\"}">>}, Req2)
            end;
        {error, too_large} ->
            reply(413, #{error => <<"request_too_large">>}, Req)
    end.

%% ===================================================================
%% Helper functions
%% ===================================================================

%% Run Fun with the path key, or answer 400 when the route carried none.
-spec with_key(cowboy_req:req(), fun((string()) -> cowboy_req:req())) ->
    cowboy_req:req().
with_key(Req, Fun) ->
    case extract_key(Req) of
        {ok, Key} -> Fun(Key);
        {error, missing_key} -> reply(400, #{error => <<"missing_key">>}, Req)
    end.

-spec extract_key(cowboy_req:req()) -> {ok, string()} | {error, missing_key}.
extract_key(Req) ->
    %% The :key binding is already percent-decoded by cowboy, so a key
    %% written as {"key": "my key"} and read back as /store/my%20key
    %% resolve to the same entry. Splitting the raw path does not.
    case cowboy_req:binding(key, Req, <<>>) of
        <<>> -> {error, missing_key};
        Key -> {ok, binary_to_list(Key)}
    end.

%% jsx:decode/2 raises on malformed input rather than returning an error,
%% so every call has to be guarded or the handler crashes into a 500.
-spec decode_json(binary()) -> {ok, jsx:json_term()} | {error, invalid_json}.
decode_json(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Decoded -> {ok, Decoded}
    catch
        _:_ -> {error, invalid_json}
    end.

-spec read_body(cowboy_req:req()) ->
    {ok, binary(), cowboy_req:req()} | {error, too_large}.
read_body(Req) ->
    try
        {ok, Body, Req2} = cowboy_req:read_body(Req, #{length => ?MAX_BODY_SIZE}),
        {ok, Body, Req2}
    catch
        _:_ ->
            {error, too_large}
    end.

-spec reply(integer(), cowboy_req:req()) -> cowboy_req:req().
reply(StatusCode, Req) ->
    cowboy_req:reply(StatusCode, json_headers(), Req).

-spec reply(integer(), binary() | map(), cowboy_req:req()) -> cowboy_req:req().
reply(StatusCode, Body, Req) when is_map(Body) ->
    reply(StatusCode, jsx:encode(Body), Req);
reply(StatusCode, Body, Req) when is_binary(Body) ->
    cowboy_req:reply(StatusCode, json_headers(), Body, Req).

%% RFC 7231 makes Allow mandatory on a 405, so a client that guessed the
%% method wrong can discover what the resource does support.
-spec method_not_allowed([binary()], cowboy_req:req()) -> cowboy_req:req().
method_not_allowed(Allowed, Req) ->
    Headers = maps:put(<<"allow">>,
                       iolist_to_binary(lists:join(<<", ">>, Allowed)),
                       json_headers()),
    cowboy_req:reply(405, Headers,
                     jsx:encode(#{error => <<"method_not_allowed">>}), Req).

json_headers() ->
    #{<<"content-type">> => <<"application/json">>}.

-spec terminate(term(), cowboy_req:req(), any()) -> ok.
terminate(_Reason, _Req, _State) ->
    ok.
