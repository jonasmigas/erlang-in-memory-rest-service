%%%-------------------------------------------------------------------
%%% @doc Integration tests driving the REST API over real HTTP.
%%%
%%% These go through cowboy rather than calling kv_store directly, which
%%% is the only way the status codes, the JSON handling and the decoding
%%% of path keys are actually covered.
%%%-------------------------------------------------------------------
-module(kv_http_tests).
-include_lib("eunit/include/eunit.hrl").

%% Bind an ephemeral port rather than the default 8080: on a developer
%% machine that port is often already taken (Docker and WSL both grab it
%% here), and on Windows SO_REUSEADDR lets a second bind succeed and then
%% silently lose connections to the other listener.
base() ->
    {ok, Port} = application:get_env(kv_store, port),
    "http://127.0.0.1:" ++ integer_to_list(Port).

free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Sock),
    ok = gen_tcp:close(Sock),
    Port.

%% ===================================================================
%% Fixture
%% ===================================================================

http_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [
      {"health check answers 200", fun health/0},
      {"store, read back, clear, read again", fun store_get_delete_cycle/0},
      {"a cleared key reads as if never set", fun cleared_matches_never_set/0},
      {"malformed JSON is a 400, not a crash", fun malformed_json/0},
      {"a percent-encoded path key names the same entry", fun percent_encoded_key/0},
      {"stopping the listener child stops the listener",
       {timeout, 30, fun listener_restart/0}}
     ]}.

setup() ->
    %% kv_store_tests starts a bare gen_server that outlives its test
    %% process; left running it makes the supervisor's start_link fail
    %% with already_started. Clear it before starting the application.
    ok = stop_stray_store(),
    {ok, _} = application:ensure_all_started(inets),
    ok = application:load(kv_store),
    ok = application:set_env(kv_store, port, free_port()),
    {ok, _} = application:ensure_all_started(kv_store),
    up = wait_for_listener(up, 100),
    ok.

cleanup(_) ->
    application:stop(kv_store),
    ok.

%% ===================================================================
%% Test cases
%% ===================================================================

health() ->
    {Status, Body} = request(get, "/health"),
    ?assertEqual(200, Status),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Body)).

store_get_delete_cycle() ->
    ?assertMatch({201, _}, request(post, "/store/cycle", "{\"value\": \"first\"}")),
    {GetStatus, Got} = request(get, "/store/cycle"),
    ?assertEqual(200, GetStatus),
    %% The brief requires both the key and the data on a successful read.
    ?assertEqual(<<"cycle">>, maps:get(<<"key">>, Got)),
    ?assertEqual(<<"first">>, maps:get(<<"value">>, Got)),
    ?assertMatch({204, _}, request(delete, "/store/cycle")),
    {GoneStatus, Gone} = request(get, "/store/cycle"),
    ?assertEqual(404, GoneStatus),
    ?assertEqual(<<"key_not_found">>, maps:get(<<"error">>, Gone)).

cleared_matches_never_set() ->
    ?assertMatch({201, _}, request(post, "/store/transient", "{\"value\": \"x\"}")),
    ?assertMatch({204, _}, request(delete, "/store/transient")),
    {ClearedStatus, ClearedBody} = request(get, "/store/transient"),
    {NeverStatus, NeverBody} = request(get, "/store/never_written"),
    ?assertEqual(NeverStatus, ClearedStatus),
    ?assertEqual(maps:get(<<"error">>, NeverBody),
                 maps:get(<<"error">>, ClearedBody)).

malformed_json() ->
    %% jsx:decode/2 raises on every one of these. Unguarded that crashed
    %% the handler, so the client saw a 500 where it should see a 400.
    ?assertMatch({400, _}, request(post, "/store", "")),
    ?assertMatch({400, _}, request(post, "/store", "{not json")),
    ?assertMatch({400, _}, request(post, "/store/somekey", "")),
    ?assertMatch({400, _}, request(put, "/store/somekey", "<xml/>")).

percent_encoded_key() ->
    %% Written through the body with a literal space...
    ?assertMatch({201, _},
                 request(post, "/store", "{\"key\": \"my key\", \"value\": \"spaced\"}")),
    %% ...and read back through the path, percent-encoded.
    {Status, Body} = request(get, "/store/my%20key"),
    ?assertEqual(200, Status),
    ?assertEqual(<<"my key">>, maps:get(<<"key">>, Body)),
    ?assertEqual(<<"spaced">>, maps:get(<<"value">>, Body)).

listener_restart() ->
    ?assertMatch({201, _}, request(post, "/store/survivor", "{\"value\": \"alive\"}")),
    StorePid = whereis(kv_store),
    Id = http_child_id(),
    %% The listener used to run under ranch's own supervisor, so this tree
    %% owned nothing: terminating the child left the listener serving, and
    %% restarting it re-ran cowboy:start_clear/3 under the same name, got
    %% {error, {already_started, _}} and badmatched into a crash loop.
    %% Stopping the child must therefore actually stop the listener.
    ok = supervisor:terminate_child(kv_store_sup, Id),
    ?assertEqual(down, wait_for_listener(down, 40)),
    ?assertMatch({ok, _}, supervisor:restart_child(kv_store_sup, Id)),
    ?assertEqual(up, wait_for_listener(up, 40)),
    %% one_for_one: the store must not have gone down with the listener,
    %% and the data it holds must have survived.
    ?assertEqual(StorePid, whereis(kv_store)),
    {Status, Body} = request(get, "/store/survivor"),
    ?assertEqual(200, Status),
    ?assertEqual(<<"alive">>, maps:get(<<"value">>, Body)).

%% ===================================================================
%% Helpers
%% ===================================================================

http_child_id() ->
    Children = supervisor:which_children(kv_store_sup),
    [Id | _] = [I || {I, _, _, _} <- Children, I =/= kv_store],
    Id.

stop_stray_store() ->
    case whereis(kv_store) of
        undefined ->
            ok;
        Pid ->
            MRef = monitor(process, Pid),
            exit(Pid, kill),
            receive
                {'DOWN', MRef, process, Pid, _} -> ok
            after 5000 ->
                {error, stray_store_not_stopped}
            end
    end.

%% Poll until the listener reaches Want (up | down), or give up and report
%% whatever it actually is so the assertion message is useful.
wait_for_listener(Want, 0) ->
    Actual = listener_state(),
    case Actual of
        Want -> Want;
        _ -> Actual
    end;
wait_for_listener(Want, N) ->
    case listener_state() of
        Want -> Want;
        _ -> timer:sleep(50), wait_for_listener(Want, N - 1)
    end.

listener_state() ->
    case httpc:request(get, {base() ++ "/health", []}, [{timeout, 1000}], []) of
        {ok, {{_Vsn, 200, _Reason}, _Headers, _Body}} -> up;
        _ -> down
    end.

request(get, Path) ->
    do_request(get, {base() ++ Path, []});
request(delete, Path) ->
    do_request(delete, {base() ++ Path, []}).

request(post, Path, Body) ->
    do_request(post, {base() ++ Path, [], "application/json", Body});
request(put, Path, Body) ->
    do_request(put, {base() ++ Path, [], "application/json", Body}).

do_request(Method, Request) ->
    {ok, {{_Vsn, Status, _Reason}, _Headers, Body}} =
        httpc:request(Method, Request, [], []),
    {Status, decode(Body)}.

decode([]) ->
    #{};
decode(Body) ->
    try jsx:decode(list_to_binary(Body), [return_maps])
    catch _:_ -> #{}
    end.
