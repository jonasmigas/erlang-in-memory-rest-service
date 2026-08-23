%%%-------------------------------------------------------------------
%%% @doc Cowboy HTTP server for the KV Store REST API.
%%% Provides endpoints for set, get, delete operations.
%%%-------------------------------------------------------------------
-module(kv_http).
-behaviour(application).

%% Application callbacks
-export([start/0, start/2, stop/0, stop/1]).
%% Supervisor child API
-export([start_link/0]).
%% Cowboy handler
-export([init/2, terminate/3]).

-define(PORT, 8080).
-define(MAX_BODY_SIZE, 1048576).  %% 1MB

%% ===================================================================
%% Supervisor child API
%% ===================================================================

%% Wraps the cowboy listener in a dedicated linked process so it has its
%% own pid for the supervisor to track (cowboy manages its own workers).
-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    Pid = spawn_link(fun() ->
        start_http_server(),
        receive stop -> ok end
    end),
    {ok, Pid}.

%% ===================================================================
%% Application callbacks (for running as a child)
%% ===================================================================

-spec start() -> {ok, pid()} | {error, any()}.
start() ->
    start(permanent, []).

-spec start(application:start_type(), any()) -> {ok, pid()} | {error, any()}.
start(_StartType, _StartArgs) ->
    start_http_server().

-spec stop() -> ok.
stop() ->
    stop(ok).

-spec stop(any()) -> ok.
stop(_State) ->
    cowboy:stop_listener(?MODULE).

%% ===================================================================
%% Internal: Start Cowboy
%% ===================================================================

start_http_server() ->
    %% Create the dispatch routes
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/store/[:key]", ?MODULE, []},      %% GET, POST, PUT, DELETE
            {"/store", ?MODULE, []},             %% POST (alternative)
            {"/health", ?MODULE, []}             %% Health check
        ]}
    ]),

    %% Start the cowboy listener
    {ok, _Pid} = cowboy:start_clear(?MODULE,
        [{port, ?PORT}],
        #{env => #{dispatch => Dispatch}}
    ),
    io:format("~n~s HTTP Server started on port ~p~n", [?MODULE, ?PORT]),
    {ok, self()}.

%% ===================================================================
%% Cowboy HTTP Handler
%% ===================================================================

-spec init(cowboy_req:req(), any()) -> {cowboy_loop, cowboy_req:req(), any()}.
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

handle_request(<<"GET">>, Path, Req, State) ->
    %% GET /store/{key}
    case extract_key(Path) of
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

handle_request(<<"POST">>, <<"/store">>, Req, State) ->
    %% POST /store with JSON body: {"key": "mykey", "value": "myvalue"}
    handle_post(Req, State);

handle_request(<<"POST">>, Path, Req, State) when Path =:= <<"/store/">> orelse Path =:= <<"/store/ ">> ->
    handle_post(Req, State);

handle_request(<<"POST">>, Path, Req, State) ->
    %% POST /store/{key} with JSON body: {"value": "myvalue"}
    case extract_key(Path) of
        {ok, Key} ->
            handle_post_with_key(Key, Req, State);
        {error, missing_key} ->
            %% Try to read from body instead
            handle_post(Req, State)
    end;

handle_request(<<"PUT">>, Path, Req, State) ->
    %% PUT /store/{key} with JSON body: {"value": "myvalue"}
    case extract_key(Path) of
        {ok, Key} ->
            handle_put(Key, Req, State);
        {error, missing_key} ->
            Response = jsx:encode(#{error => <<"key_required_in_path">>}),
            {reply(400, Response, Req), State}
    end;

handle_request(<<"DELETE">>, Path, Req, State) ->
    %% DELETE /store/{key}
    case extract_key(Path) of
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
%% Helper functions for handling POST/PUT
%% ===================================================================

handle_post(Req, State) ->
    case read_body(Req) of
        {ok, Body, Req2} ->
            case jsx:decode(Body, [return_maps]) of
                #{<<"key">> := Key, <<"value">> := Value} when is_binary(Key), Key /= <<>> ->
                    KeyStr = binary_to_list(Key),
                    case kv_store:set(KeyStr, Value) of
                        ok ->
                            Response = jsx:encode(#{key => Key, value => Value, status => <<"stored">>}),
                            {reply(201, Response, Req2), State};
                        {error, invalid_key} ->
                            Response = jsx:encode(#{error => <<"invalid_key">>}),
                            {reply(400, Response, Req2), State}
                    end;
                #{<<"key">> := Key} when is_binary(Key) ->
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

handle_post_with_key(Key, Req, State) when is_list(Key), Key /= [] ->
    case read_body(Req) of
        {ok, Body, Req2} ->
            case jsx:decode(Body, [return_maps]) of
                #{<<"value">> := Value} ->
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
    end;
handle_post_with_key(_Key, Req, State) ->
    Response = jsx:encode(#{error => <<"invalid_key">>}),
    {reply(400, Response, Req), State}.

handle_put(Key, Req, State) when is_list(Key), Key /= [] ->
    %% PUT is handled the same as POST with key in path
    handle_post_with_key(Key, Req, State);
handle_put(_Key, Req, State) ->
    Response = jsx:encode(#{error => <<"invalid_key">>}),
    {reply(400, Response, Req), State}.

%% ===================================================================
%% Helper functions
%% ===================================================================

-spec extract_key(binary()) -> {ok, string()} | {error, missing_key}.
extract_key(Path) ->
    %% Path is like <<"/store/mykey">>
    Parts = binary:split(Path, <<"/">>, [global]),
    case Parts of
        [<<"">>, <<"store">>, Key] when byte_size(Key) > 0 ->
            {ok, binary_to_list(Key)};
        [<<"">>, <<"store">>, Key, <<"">>] when byte_size(Key) > 0 ->
            {ok, binary_to_list(Key)};
        [<<"">>, <<"store">>, <<>>] ->
            {error, missing_key};
        _ ->
            {error, missing_key}
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

-spec reply(integer(), binary() | map(), cowboy_req:req()) -> cowboy_req:req().
reply(StatusCode, Body, Req) when is_binary(Body) ->
    cowboy_req:reply(StatusCode, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req);
reply(StatusCode, Body, Req) when is_map(Body) ->
    reply(StatusCode, jsx:encode(Body), Req).

-spec terminate(term(), cowboy_req:req(), any()) -> ok.
terminate(_Reason, _Req, _State) ->
    ok.