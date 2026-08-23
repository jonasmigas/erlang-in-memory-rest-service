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
%% Fixture guard
%%
%% Outside the fixture on purpose: it asserts that clearing a stray
%% store does not take this very process with it. If the kill ever
%% propagates along the link again, this test does not fail -- the
%% runner dies and eunit reports the whole module cancelled, which is
%% exactly the failure being guarded against.
%% ===================================================================

stray_store_is_stopped_without_killing_the_runner_test() ->
    %% kv_store_tests may already have left one registered, depending on
    %% the order eunit picked; clear that before starting our own.
    ok = stop_stray_store(),
    {ok, Pid} = kv_store:start_link(),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(ok, stop_stray_store()),
    ?assert(is_process_alive(self())),
    ?assertEqual(undefined, whereis(kv_store)).

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
      {"put writes a key the same way post does", fun put_with_path_key/0},
      {"the keyless routes still take the key from the body",
       fun keyless_routes_read_the_body/0},
      {"a request with no key at all is a 400", fun no_key_anywhere/0},
      {"a method the route does not serve is a 405 naming what it does",
       fun method_not_allowed/0},
      {"the health route serves no writes", fun health_rejects_writes/0},
      {"the health route tolerates a trailing slash",
       fun health_trailing_slash/0},
      {"head answers wherever get does", fun head_mirrors_get/0},
      {"an unmatched path is a json 404", fun unmatched_path_is_json/0},
      {"an overwrite is a 200, a first write a 201",
       fun overwrite_is_not_created/0},
      {"stopping the listener child stops the listener",
       {timeout, 30, fun listener_restart/0}}
     ]}.

setup() ->
    %% kv_store_tests starts a bare gen_server that outlives its test
    %% process; left running it makes the supervisor's start_link fail
    %% with already_started. Clear it before starting the application.
    ok = stop_stray_store(),
    {ok, _} = application:ensure_all_started(inets),
    ok = load_kv_store(),
    ok = application:set_env(kv_store, port, free_port()),
    {ok, _} = application:ensure_all_started(kv_store),
    up = wait_for_listener(up, 100),
    ok.

cleanup(_) ->
    application:stop(kv_store),
    %% Unload as well. application:stop/1 leaves the application loaded,
    %% so a second run of this fixture in the same VM would fail in
    %% setup/0 with {error, {already_loaded, kv_store}}.
    application:unload(kv_store),
    ok.

%% Tolerate an application left loaded by an earlier aborted run, so a
%% crashed fixture does not poison every later one.
load_kv_store() ->
    case application:load(kv_store) of
        ok -> ok;
        {error, {already_loaded, kv_store}} -> ok;
        Error -> Error
    end.

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

put_with_path_key() ->
    %% malformed_json/0 already drove PUT, but only into a 400. Nothing
    %% covered a successful PUT write, so the two verbs could drift apart
    %% on the happy path without a test noticing.
    ?assertMatch({201, _}, request(put, "/store/put_key", "{\"value\": \"via_put\"}")),
    {Status, Body} = request(get, "/store/put_key"),
    ?assertEqual(200, Status),
    ?assertEqual(<<"via_put">>, maps:get(<<"value">>, Body)).

keyless_routes_read_the_body() ->
    %% /store and /store/ both reach the handler with no :key binding and
    %% must fall back to the key in the body. These used to be matched by
    %% path literals -- one of them <<"/store/ ">>, with a space, which no
    %% request can produce -- rather than by the absent binding.
    ?assertMatch({201, _},
                 request(post, "/store", "{\"key\": \"no_slash\", \"value\": \"a\"}")),
    ?assertMatch({201, _},
                 request(post, "/store/", "{\"key\": \"trailing_slash\", \"value\": \"b\"}")),
    ?assertMatch({200, #{<<"value">> := <<"a">>}}, request(get, "/store/no_slash")),
    ?assertMatch({200, #{<<"value">> := <<"b">>}}, request(get, "/store/trailing_slash")).

no_key_anywhere() ->
    %% No key in the path and none in the body is a client error, not a
    %% crash and not a silent write.
    {GetStatus, GetBody} = request(get, "/store"),
    ?assertEqual(400, GetStatus),
    ?assertEqual(<<"missing_key">>, maps:get(<<"error">>, GetBody)),
    ?assertMatch({400, _}, request(get, "/store/")),
    ?assertMatch({400, _}, request(delete, "/store")),
    {PutStatus, PutBody} = request(put, "/store", "{\"value\": \"nowhere\"}"),
    ?assertEqual(400, PutStatus),
    ?assertEqual(<<"key_required_in_path">>, maps:get(<<"error">>, PutBody)),
    ?assertMatch({400, _}, request(post, "/store", "{\"value\": \"keyless\"}")).

method_not_allowed() ->
    {Status, Headers, Body} = request_with_headers(options, "/store/anything"),
    ?assertEqual(405, Status),
    ?assertEqual(<<"method_not_allowed">>, maps:get(<<"error">>, Body)),
    %% RFC 7231 makes Allow mandatory on a 405. Asserting only the status
    %% and body would pin its absence as correct.
    ?assertEqual("GET, HEAD, POST, PUT, DELETE",
                 proplists:get_value("allow", Headers)).

health_rejects_writes() ->
    %% /health shares a handler module with /store. While the handler
    %% decided the resource from the request rather than from the route,
    %% an absent :key binding read as "the key is in the body" -- so
    %% POST /health returned 201 and really wrote to the store, and
    %% PUT/DELETE answered with errors about a key /health has no concept
    %% of. Every verb but GET must be a 405 that says so.
    Write = "{\"key\": \"via_health\", \"value\": \"x\"}",
    {PostStatus, PostHeaders, _} = request_with_headers(post, "/health", Write),
    ?assertEqual(405, PostStatus),
    ?assertEqual("GET, HEAD", proplists:get_value("allow", PostHeaders)),
    ?assertMatch({405, _}, request(put, "/health", "{\"value\": \"x\"}")),
    ?assertMatch({405, _}, request(delete, "/health")),
    %% and the store is untouched by any of them
    ?assertMatch({404, _}, request(get, "/store/via_health")).

unmatched_path_is_json() ->
    %% The README promises every response is JSON, but an unmatched path
    %% never reached this handler: cowboy's router replied 404 with no
    %% body and no content-type, so a client decoding error bodies parsed
    %% one 404 and crashed on the other. decode([]) returning #{} in this
    %% suite is what let it go unnoticed, so assert on the field.
    {Status, Body} = request(get, "/nope"),
    ?assertEqual(404, Status),
    ?assertEqual(<<"not_found">>, maps:get(<<"error">>, Body)),
    %% deeper than the store route accepts
    {DeepStatus, DeepBody} = request(get, "/store/a/b"),
    ?assertEqual(404, DeepStatus),
    ?assertEqual(<<"not_found">>, maps:get(<<"error">>, DeepBody)),
    %% and a missing key still reports as a missing key, not a bad path
    ?assertMatch({404, #{<<"error">> := <<"key_not_found">>}},
                 request(get, "/store/never_written_json")).

overwrite_is_not_created() ->
    %% Both POST and PUT answered 201 unconditionally, so a client using
    %% the status to tell a create from an update always read "created".
    %% kv_store:set/2 reports which it did, so the handler no longer has
    %% to guess or read the key back first.
    ?assertMatch({201, _}, request(put, "/store/twice", "{\"value\": \"one\"}")),
    ?assertMatch({200, _}, request(put, "/store/twice", "{\"value\": \"two\"}")),
    ?assertMatch({200, _}, request(post, "/store/twice", "{\"value\": \"three\"}")),
    ?assertMatch({200, #{<<"value">> := <<"three">>}}, request(get, "/store/twice")),
    %% the body-key form agrees
    ?assertMatch({201, _},
                 request(post, "/store", "{\"key\": \"body_twice\", \"value\": \"a\"}")),
    ?assertMatch({200, _},
                 request(post, "/store", "{\"key\": \"body_twice\", \"value\": \"b\"}")),
    %% and deleting it makes the next write a create again
    ?assertMatch({204, _}, request(delete, "/store/twice")),
    ?assertMatch({201, _}, request(put, "/store/twice", "{\"value\": \"four\"}")).

head_mirrors_get() ->
    %% HEAD used to fall to the method-not-allowed clause, so curl -I and
    %% any load balancer probing with HEAD saw 405 on resources that
    %% answered GET. cowboy drops the body for HEAD itself, so the status
    %% is the whole contract here.
    ?assertMatch({201, _}, request(post, "/store/head_key", "{\"value\": \"h\"}")),
    ?assertMatch({200, _}, request(head, "/store/head_key")),
    ?assertMatch({200, _}, request(head, "/health")),
    %% and it still reports absence the way GET does
    ?assertMatch({404, _}, request(head, "/store/head_never_written")).

health_trailing_slash() ->
    %% cowboy normalises /health/ to the same route, so it reaches this
    %% handler; matching the raw path string missed it and dropped the
    %% request into the store's GET clause as a 400. A probe URL written
    %% with a trailing slash would report the service down.
    {Status, Body} = request(get, "/health/"),
    ?assertEqual(200, Status),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Body)).

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

%% kv_store_tests starts its gen_server with start_link/0 from the eunit
%% test process, so a stray is linked to the runner. exit(Pid, kill)
%% follows that link and kills the runner too: the suite aborts with
%% "unexpected termination of test process ::killed" and reports
%% Failed: 0 while silently cancelling every test in this module. Only
%% rebar3's alphabetical ordering hid it. gen_server:stop/3 terminates
%% the process with reason normal, which linked processes ignore.
stop_stray_store() ->
    case whereis(kv_store) of
        undefined ->
            ok;
        Pid ->
            try gen_server:stop(Pid, normal, 5000) of
                ok -> ok
            catch
                exit:noproc -> ok;
                _:_ -> {error, stray_store_not_stopped}
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
    do_request(delete, {base() ++ Path, []});
request(options, Path) ->
    do_request(options, {base() ++ Path, []});
request(head, Path) ->
    do_request(head, {base() ++ Path, []}).

request(post, Path, Body) ->
    do_request(post, {base() ++ Path, [], "application/json", Body});
request(put, Path, Body) ->
    do_request(put, {base() ++ Path, [], "application/json", Body}).

do_request(Method, Request) ->
    {Status, _Headers, Body} = do_request_with_headers(Method, Request),
    {Status, Body}.

%% Same as request/2,3 but keeps the response headers, for the cases where
%% the header is the contract being asserted.
request_with_headers(options, Path) ->
    do_request_with_headers(options, {base() ++ Path, []}).

request_with_headers(post, Path, Body) ->
    do_request_with_headers(post, {base() ++ Path, [], "application/json", Body}).

do_request_with_headers(Method, Request) ->
    {ok, {{_Vsn, Status, _Reason}, Headers, Body}} =
        httpc:request(Method, Request, [], []),
    {Status, Headers, decode(Body)}.

decode([]) ->
    #{};
decode(Body) ->
    try jsx:decode(list_to_binary(Body), [return_maps])
    catch _:_ -> #{}
    end.
