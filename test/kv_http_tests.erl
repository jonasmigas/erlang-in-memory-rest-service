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

listen_port() ->
    {ok, Port} = application:get_env(kv_store, port),
    Port.

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
      {"metrics are exposed in prometheus text", fun metrics_exposed/0},
      {"a counter moves when the thing it counts happens",
       fun metrics_count_what_happened/0},
      {"the metrics route serves no writes", fun metrics_rejects_writes/0},
      {"an overwrite is a 200, a first write a 201",
       fun overwrite_is_not_created/0},
      {"a wedged store still serves reads and 503s writes",
       {timeout, 30, fun store_unavailable/0}},
      {"300 concurrent writes then 300 concurrent reads agree",
       {timeout, 120, fun concurrent_load/0}},
      {"a body that never arrives is a 408, not a 413",
       {timeout, 30, fun slow_body_is_a_timeout/0}},
      {"a body over the cap is still a 413", {timeout, 30, fun oversized_body/0}},
      {"a key that cannot round-trip is rejected", fun unusable_keys/0},
      {"a created resource says where it went", fun created_has_location/0},
      {"a body with no value says so, either way",
       fun missing_value_agrees/0},
      {"stopping the listener child stops the listener",
       {timeout, 30, fun listener_restart/0}},
      %% Last on purpose: it takes the store down and back up, which
      %% empties the table every earlier test has been writing to.
      {"the health check reports the store, not the listener",
       {timeout, 30, fun health_reports_the_store/0}}
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

metrics_exposed() ->
    %% Drive two known outcomes first, so the scrape has something to say.
    ?assertMatch({201, _}, request(put, "/store/metric_probe", "{\"value\": \"m\"}")),
    ?assertMatch({200, _}, request(get, "/store/metric_probe")),
    {Status, Headers, Body} = raw_request(get, "/metrics"),
    ?assertEqual(200, Status),
    %% Prometheus text, not JSON: this is the one endpoint the all-JSON
    %% rule does not cover, and a scraper decides by content-type.
    ?assertEqual("text/plain; version=0.0.4",
                 proplists:get_value("content-type", Headers)),
    ?assertNotEqual(nomatch, string:find(Body, "# TYPE kv_http_requests_total counter")),
    ?assertNotEqual(nomatch, string:find(Body, "method=\"GET\",status=\"200\"")),
    ?assertNotEqual(nomatch, string:find(Body, "op=\"set\",result=\"created\"")),
    %% Gauges are read at scrape time, so they describe now, not last time.
    ?assertNotEqual(nomatch, string:find(Body, "# TYPE kv_store_entries gauge")),
    ?assert(metric(Body, "kv_store_entries ") > 0).

metrics_count_what_happened() ->
    Label = "kv_http_requests_total{method=\"DELETE\",status=\"404\"} ",
    {_, _, Before} = raw_request(get, "/metrics"),
    ?assertMatch({404, _}, request(delete, "/store/never_existed_at_all")),
    {_, _, After} = raw_request(get, "/metrics"),
    %% Asserting it moved, not what it equals: the suite shares one store
    %% and a test that pins an absolute count breaks when another is added.
    ?assert(metric(After, Label) > metric(Before, Label)),
    MissLabel = "kv_store_operations_total{op=\"delete\",result=\"miss\"} ",
    ?assert(metric(After, MissLabel) > metric(Before, MissLabel)).

metrics_rejects_writes() ->
    ?assertMatch({405, _}, request(put, "/metrics", "{\"value\": \"x\"}")),
    ?assertMatch({405, _}, request(delete, "/metrics")).

%% Read the number off a metrics line, given everything before it.
%%
%% Anchored to the start of a line: an unlabelled name like
%% "kv_store_entries " also appears inside "# HELP kv_store_entries ...",
%% which comes first and is followed by prose rather than a number.
metric(Body, Prefix) ->
    case string:find(Body, "\n" ++ Prefix) of
        nomatch ->
            0;
        Found ->
            Tail = string:slice(Found, string:length(Prefix) + 1),
            case string:take(Tail, "0123456789") of
                {[], _} -> 0;
                {Digits, _} -> list_to_integer(Digits)
            end
    end.

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

store_unavailable() ->
    %% The listener survives a kv_store restart by design (one_for_one),
    %% so requests do land while the store is unreachable. Those calls
    %% used to exit out of init/2 and cowboy answered with a bodiless
    %% 500 -- unparseable for a client that decodes error bodies.
    ?assertMatch({201, _}, request(put, "/store/frozen", "{\"value\": \"v\"}")),
    ok = application:set_env(kv_store, call_timeout, 200),
    Pid = whereis(kv_store),
    ok = sys:suspend(Pid),
    try
        %% Reads come straight from the table, so a store process that is
        %% wedged or busy no longer takes the read path down with it.
        %% This is the point of reading outside the gen_server: the
        %% request that is stuck is the only one that suffers.
        ?assertMatch({200, #{<<"value">> := <<"v">>}}, request(get, "/store/frozen")),
        %% Writes still go through the process, and still say so plainly
        %% rather than hanging or answering with a bodiless 500.
        ?assertMatch({503, #{<<"error">> := <<"store_unavailable">>}},
                     request(put, "/store/frozen", "{\"value\": \"w\"}")),
        ?assertMatch({503, _}, request(post, "/store", "{\"key\": \"f\", \"value\": 1}")),
        ?assertMatch({503, _}, request(delete, "/store/frozen")),
        %% /health asks kv_store:ready/0, which a suspended process still
        %% satisfies: it is registered and its table is there. So the probe
        %% catches a store that is gone and not one that is wedged, which
        %% is the documented trade -- checking for wedged means calling
        %% into the mailbox this test has deliberately blocked.
        ?assertMatch({200, _}, request(get, "/health"))
    after
        ok = sys:resume(Pid),
        %% Unset rather than restore a literal: the literal was a second
        %% copy of the default, and it went stale the moment the default
        %% moved.
        ok = application:unset_env(kv_store, call_timeout)
    end,
    %% and the listener recovers on its own. Note a call that timed out
    %% was still delivered: the store applies the queued writes once it
    %% resumes, so /store/frozen is whatever those left behind. Assert
    %% recovery on a fresh key rather than on that one.
    ?assertMatch({201, _}, request(put, "/store/after_thaw", "{\"value\": \"t\"}")),
    ?assertMatch({200, #{<<"value">> := <<"t">>}}, request(get, "/store/after_thaw")).

slow_body_is_a_timeout() ->
    %% read_body/1 matched only {ok, ...} and called everything else
    %% too_large, but cowboy also answers {more, ...} when the read
    %% period expires. A client that stalled mid-body was told its
    %% handful of bytes exceeded 1MB, and the write was dropped.
    %% Wide enough that ordinary scheduling jitter cannot look like the
    %% deadline expiring -- at 400ms this flaked once, reporting a status
    %% that was not 408 on a run that had changed nothing.
    ok = application:set_env(kv_store, body_deadline, 1500),
    try
        {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, listen_port(),
                                     [binary, {active, false}, {packet, raw}]),
        %% headers promise 20 bytes; none of them ever follow
        ok = gen_tcp:send(Sock,
             "POST /store/slowbody HTTP/1.1\r\n"
             "Host: 127.0.0.1\r\n"
             "Content-Type: application/json\r\n"
             "Content-Length: 20\r\n"
             "Connection: close\r\n\r\n"),
        {ok, Resp} = gen_tcp:recv(Sock, 0, 10000),
        gen_tcp:close(Sock),
        ?assertMatch({match, _}, re:run(Resp, "^HTTP/1\\.1 408 ")),
        ?assertMatch({match, _}, re:run(Resp, "request_timeout"))
    after
        ok = application:set_env(kv_store, body_deadline, 15000)
    end,
    %% and nothing was written under that key
    ?assertMatch({404, _}, request(get, "/store/slowbody")).

oversized_body() ->
    %% The cap itself still holds, and still reports as a size problem.
    Big = binary:copy(<<"x">>, 1048600),
    Body = <<"{\"value\": \"", Big/binary, "\"}">>,
    ?assertMatch({413, #{<<"error">> := <<"request_too_large">>}},
                 request(put, "/store/toobig", binary_to_list(Body))),
    ?assertMatch({404, _}, request(get, "/store/toobig")).

unusable_keys() ->
    %% A client reads a key out of a response and puts it back in a URL.
    %% These cannot survive that, so storing them only produces an entry
    %% nobody can name.

    %% Not valid UTF-8: jsx encodes it as U+FFFD, so /store/%FF and
    %% /store/%FE both reported the same key, and asking for that back
    %% was a third key that did not exist.
    ?assertMatch({400, #{<<"error">> := <<"invalid_key">>}},
                 request(put, "/store/%FF", "{\"value\": \"raw\"}")),
    ?assertMatch({400, _}, request(get, "/store/%FE")),

    %% Dot segments: cowboy removes these before a binding exists, so
    %% the entry was writable through the body and then unreachable and
    %% undeletable through the path.
    ?assertMatch({400, #{<<"error">> := <<"invalid_key">>}},
                 request(post, "/store", "{\"key\": \"..\", \"value\": \"v\"}")),
    ?assertMatch({400, _}, request(post, "/store", "{\"key\": \".\", \"value\": \"v\"}")),

    %% An empty key names the empty key, not a missing value.
    ?assertMatch({400, #{<<"error">> := <<"invalid_key">>}},
                 request(post, "/store", "{\"key\": \"\", \"value\": \"v\"}")).

created_has_location() ->
    %% POST /store puts the resource somewhere the request URI does not
    %% name, so 201 has to say where -- percent-encoded, since the key
    %% may not be URL-safe.
    {Status, Headers, _} =
        request_with_headers(post, "/store", "{\"key\": \"loc key\", \"value\": \"v\"}"),
    ?assertEqual(201, Status),
    ?assertEqual("/store/loc%20key", proplists:get_value("location", Headers)),
    %% and the path it named really is the entry
    ?assertMatch({200, #{<<"value">> := <<"v">>}}, request(get, "/store/loc%20key")),
    %% a replacement is a 200 and names nothing new
    {Again, AgainHeaders, _} =
        request_with_headers(post, "/store", "{\"key\": \"loc key\", \"value\": \"w\"}"),
    ?assertEqual(200, Again),
    ?assertEqual(undefined, proplists:get_value("location", AgainHeaders)).

missing_value_agrees() ->
    %% Same mistake, same answer, whichever form carried the key. The
    %% path form used to call this valid JSON invalid.
    ?assertMatch({400, #{<<"error">> := <<"missing_value">>}},
                 request(post, "/store", "{\"key\": \"novalue\"}")),
    ?assertMatch({400, #{<<"error">> := <<"missing_value">>}},
                 request(put, "/store/novalue", "{}")),
    %% and genuinely malformed JSON still reports as malformed
    ?assertMatch({400, #{<<"error">> := <<"invalid_json">>}},
                 request(put, "/store/novalue", "{not json")).

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

%% The listener answering at all proves the listener is up, which is the
%% one thing a probe does not need to be told. With the store terminated
%% the node cannot serve a single key, and the probe has to say so --
%% otherwise an orchestrator keeps sending traffic to a node whose every
%% write is a 503.
health_reports_the_store() ->
    ?assertMatch({200, #{<<"status">> := <<"ok">>}}, request(get, "/health")),
    ok = supervisor:terminate_child(kv_store_sup, kv_store),
    try
        {Status, Body} = request(get, "/health"),
        ?assertEqual(503, Status),
        ?assertEqual(<<"store_unavailable">>, maps:get(<<"error">>, Body)),
        %% and the store route agrees, rather than the two disagreeing
        ?assertMatch({503, _}, request(get, "/store/anything"))
    after
        {ok, _} = supervisor:restart_child(kv_store_sup, kv_store)
    end,
    ?assertMatch({200, #{<<"status">> := <<"ok">>}}, request(get, "/health")).

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

%% The design document claims this result; until now nothing produced it.
%% Every other test here drives one request at a time, so the property the
%% whole store design rests on -- that concurrent requests do not queue
%% behind each other and do not see each other's data -- was the one
%% property never exercised.
%%
%% Each writer sends a value derived from its own key, so a read that
%% returns the wrong value proves requests crossed, which a plain 200 would
%% not catch.
concurrent_load() ->
    N = 300,
    Keys = [concurrent_key(I) || I <- lists:seq(1, N)],

    with_parallel_sessions(
      fun() ->
              Writes = pmap(fun(K) ->
                                    request(put, "/store/" ++ binary_to_list(K),
                                            "{\"value\": \"" ++
                                                binary_to_list(concurrent_value(K)) ++ "\"}")
                            end, Keys),
              ?assertEqual([], [W || W <- Writes, not is_created(W)]),

              Reads = pmap(fun(K) ->
                                   {K, request(get, "/store/" ++ binary_to_list(K))}
                           end, Keys),
              ?assertEqual([], [R || R <- Reads, not read_matches(R)]),
              ?assertEqual(N, length(Reads))
      end).

concurrent_key(I) ->
    iolist_to_binary(["conc_", integer_to_list(I)]).

%% Distinct per key, so a crossed response is a failed assertion rather
%% than a coincidence.
concurrent_value(Key) ->
    <<"value_of_", Key/binary>>.

is_created({201, _}) -> true;
is_created(_) -> false.

read_matches({Key, {200, Body}}) ->
    maps:get(<<"key">>, Body, undefined) =:= Key andalso
        maps:get(<<"value">>, Body, undefined) =:= concurrent_value(Key);
read_matches(_) ->
    false.

%% ===================================================================
%% Helpers
%% ===================================================================

%% httpc keeps two sessions per host by default, which would funnel three
%% hundred "concurrent" requests through two connections and quietly test
%% nothing. Raised for the duration and put back, since the option is
%% global to the profile and every other test here shares it.
with_parallel_sessions(Fun) ->
    {ok, [{max_sessions, Old}]} = httpc:get_options([max_sessions]),
    ok = httpc:set_options([{max_sessions, 64}]),
    try Fun()
    after
        httpc:set_options([{max_sessions, Old}])
    end.

%% The result travels in the exit reason, so there is no window between a
%% worker's message and its DOWN in which a crash could be read as a
%% missing reply.
pmap(Fun, Items) ->
    Refs = [begin
                {_Pid, Ref} = spawn_monitor(fun() -> exit({ok, Fun(Item)}) end),
                Ref
            end || Item <- Items],
    [collect(Ref) || Ref <- Refs].

collect(Ref) ->
    receive
        {'DOWN', Ref, process, _Pid, {ok, Result}} -> Result;
        {'DOWN', Ref, process, _Pid, Reason} -> {worker_died, Reason}
    after 60000 ->
        {worker_stuck, Ref}
    end.

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

%% Undecoded, for the one endpoint that does not answer in JSON.
raw_request(get, Path) ->
    {ok, {{_Vsn, Status, _Reason}, Headers, Body}} =
        httpc:request(get, {base() ++ Path, []}, [], []),
    {Status, Headers, Body}.

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
