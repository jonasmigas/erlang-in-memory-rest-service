%%%-------------------------------------------------------------------
%%% @doc Cowboy HTTP handler for the KV Store REST API.
%%% Provides endpoints for set, get, delete operations.
%%%-------------------------------------------------------------------
-module(kv_http).
-behaviour(cowboy_handler).

%% Supervisor child API
-export([child_spec/0]).
%% Cowboy handler
-export([init/2, terminate/3]).

-define(DEFAULT_PORT, 8080).
-define(MAX_BODY_SIZE, 1048576).  %% 1MB

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

%% The optional segment in "/store/[:key]" already matches /store and
%% /store/ with the binding left unset, so a separate "/store" route
%% would be a second dispatch entry the router never reaches.
-spec dispatch() -> cowboy_router:dispatch_rules().
dispatch() ->
    cowboy_router:compile([
        {'_', [
            {"/store/[:key]", ?MODULE, []},      %% GET, POST, PUT, DELETE
            {"/health", ?MODULE, []}             %% Health check
        ]}
    ]).

%% ===================================================================
%% Cowboy HTTP Handler
%% ===================================================================

-spec init(cowboy_req:req(), any()) -> {ok, cowboy_req:req(), any()}.
init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path(Req0),

    %% Handle the request based on method and path
    {Req, Resp} = handle_request(Method, Path, Req0, State),
    {ok, Req, Resp}.

-spec handle_request(binary(), binary(), cowboy_req:req(), any()) ->
    {cowboy_req:req(), any()}.
handle_request(<<"GET">>, <<"/health">>, Req, State) ->
    %% Health check endpoint
    Response = jsx:encode(#{status => ok, timestamp => os:system_time(second)}),
    {reply(200, Response, Req), State};

handle_request(<<"GET">>, _Path, Req, State) ->
    %% GET /store/{key}
    case extract_key(Req) of
        {ok, Key} ->
            case kv_store:get(Key) of
                {ok, Key, Value} ->
                    Response = jsx:encode(#{key => list_to_binary(Key), value => Value}),
                    {reply(200, Response, Req), State};
                {error, not_found} ->
                    Response = jsx:encode(#{error => <<"key_not_found">>, key => list_to_binary(Key)}),
                    {reply(404, Response, Req), State};
                {error, invalid_key} ->
                    Response = jsx:encode(#{error => <<"invalid_key">>}),
                    {reply(400, Response, Req), State}
            end;
        {error, missing_key} ->
            Response = jsx:encode(#{error => <<"missing_key">>}),
            {reply(400, Response, Req), State}
    end;

%% POST /store/{key} with {"value": ...}, or POST /store with the key in
%% the body. /store and /store/ both arrive here with no :key binding, so
%% the fallback covers them without matching path literals.
handle_request(<<"POST">>, _Path, Req, State) ->
    case extract_key(Req) of
        {ok, Key} ->
            store_with_key(Key, Req, State);
        {error, missing_key} ->
            store_from_body(Req, State)
    end;

handle_request(<<"PUT">>, _Path, Req, State) ->
    %% PUT /store/{key} with JSON body: {"value": "myvalue"}
    case extract_key(Req) of
        {ok, Key} ->
            store_with_key(Key, Req, State);
        {error, missing_key} ->
            Response = jsx:encode(#{error => <<"key_required_in_path">>}),
            {reply(400, Response, Req), State}
    end;

handle_request(<<"DELETE">>, _Path, Req, State) ->
    %% DELETE /store/{key}
    case extract_key(Req) of
        {ok, Key} ->
            case kv_store:delete(Key) of
                ok ->
                    {reply(204, Req), State};
                {error, not_found} ->
                    Response = jsx:encode(#{error => <<"key_not_found">>, key => list_to_binary(Key)}),
                    {reply(404, Response, Req), State};
                {error, invalid_key} ->
                    Response = jsx:encode(#{error => <<"invalid_key">>}),
                    {reply(400, Response, Req), State}
            end;
        {error, missing_key} ->
            Response = jsx:encode(#{error => <<"missing_key">>}),
            {reply(400, Response, Req), State}
    end;

handle_request(_, _, Req, State) ->
    %% Method not allowed
    Response = jsx:encode(#{error => <<"method_not_allowed">>}),
    {reply(405, Response, Req), State}.

%% ===================================================================
%% Helper functions for storing a value
%% ===================================================================

%% The key comes from the body: {"key": "mykey", "value": "myvalue"}.
store_from_body(Req, State) ->
    case read_body(Req) of
        {ok, Body, Req2} ->
            case decode_json(Body) of
                {ok, #{<<"key">> := Key, <<"value">> := Value}} when is_binary(Key), Key /= <<>> ->
                    KeyStr = binary_to_list(Key),
                    case kv_store:set(KeyStr, Value) of
                        ok ->
                            Response = jsx:encode(#{key => Key, value => Value, status => <<"stored">>}),
                            {reply(201, Response, Req2), State};
                        {error, invalid_key} ->
                            Response = jsx:encode(#{error => <<"invalid_key">>}),
                            {reply(400, Response, Req2), State}
                    end;
                {ok, #{<<"key">> := Key}} when is_binary(Key) ->
                    %% Missing value
                    Response = jsx:encode(#{error => <<"missing_value">>}),
                    {reply(400, Response, Req2), State};
                _ ->
                    Response = jsx:encode(#{error => <<"invalid_json">>, message => <<"Expected {\"key\":\"...\", \"value\":\"...\"}">>}),
                    {reply(400, Response, Req2), State}
            end;
        {error, too_large} ->
            Response = jsx:encode(#{error => <<"request_too_large">>}),
            {reply(413, Response, Req), State};
        {error, _} ->
            Response = jsx:encode(#{error => <<"bad_request">>}),
            {reply(400, Response, Req), State}
    end.

%% The key came from the path, so the body carries only {"value": ...}.
%% extract_key/1 never yields an empty key, so there is no empty-key clause
%% here; kv_store:set/2 still reports invalid_key as part of its contract.
store_with_key(Key, Req, State) ->
    case read_body(Req) of
        {ok, Body, Req2} ->
            case decode_json(Body) of
                {ok, #{<<"value">> := Value}} ->
                    case kv_store:set(Key, Value) of
                        ok ->
                            Response = jsx:encode(#{key => list_to_binary(Key), value => Value, status => <<"stored">>}),
                            {reply(201, Response, Req2), State};
                        {error, invalid_key} ->
                            Response = jsx:encode(#{error => <<"invalid_key">>}),
                            {reply(400, Response, Req2), State}
                    end;
                _ ->
                    Response = jsx:encode(#{error => <<"invalid_json">>, message => <<"Expected {\"value\":\"...\"}">>}),
                    {reply(400, Response, Req2), State}
            end;
        {error, too_large} ->
            Response = jsx:encode(#{error => <<"request_too_large">>}),
            {reply(413, Response, Req), State};
        {error, _} ->
            Response = jsx:encode(#{error => <<"bad_request">>}),
            {reply(400, Response, Req), State}
    end.

%% ===================================================================
%% Helper functions
%% ===================================================================

-spec extract_key(cowboy_req:req()) -> {ok, string()} | {error, missing_key}.
extract_key(Req) ->
    %% The :key binding is already percent-decoded by cowboy, so a key
    %% written as {"key": "my key"} and read back as /store/my%20key
    %% resolve to the same entry. Splitting the raw path does not.
    case cowboy_req:binding(key, Req) of
        undefined ->
            {error, missing_key};
        <<>> ->
            {error, missing_key};
        Key ->
            {ok, binary_to_list(Key)}
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

-spec read_body(cowboy_req:req()) -> {ok, binary(), cowboy_req:req()} | {error, any()}.
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
    cowboy_req:reply(StatusCode, #{
        <<"content-type">> => <<"application/json">>
    }, Req).

-spec reply(integer(), binary(), cowboy_req:req()) -> cowboy_req:req().
reply(StatusCode, Body, Req) when is_binary(Body) ->
    cowboy_req:reply(StatusCode, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req).

-spec terminate(term(), cowboy_req:req(), any()) -> ok.
terminate(_Reason, _Req, _State) ->
    ok.
