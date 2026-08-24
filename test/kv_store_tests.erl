%%%-------------------------------------------------------------------
%%% @doc Unit tests for the KV Store.
%%%-------------------------------------------------------------------
-module(kv_store_tests).
-include_lib("eunit/include/eunit.hrl").

%% Setup/teardown
%%
%% start_link/0 is called from the eunit test process, which exits normally
%% between tests, so the store it started survives and every test in this
%% module shares one table. Clearing it here is what makes each test start
%% from a known state: get_all_test asserts an absolute count, and it
%% passed only because clear_all_test happened to run immediately before
%% it. Run it any earlier -- a rename, a new test, a different eunit
%% ordering -- and it counted the keys other tests had left behind.
setup() ->
    case whereis(kv_store) of
        undefined -> {ok, _} = kv_store:start_link();
        _Pid -> ok
    end,
    ok = kv_store:clear_all(),
    ok.

teardown(_) ->
    ok.

%% ===================================================================
%% Test cases
%% ===================================================================

set_get_test() ->
    setup(),
    {ok, _} = kv_store:set(<<"test_key">>, "test_value"),
    {ok, <<"test_key">>, "test_value"} = kv_store:get(<<"test_key">>),
    teardown(ok).

set_get_integer_test() ->
    setup(),
    {ok, _} = kv_store:set(<<"number">>, 42),
    {ok, <<"number">>, 42} = kv_store:get(<<"number">>),
    teardown(ok).

set_get_map_test() ->
    setup(),
    Value = #{name => <<"João">>, age => 30},
    {ok, _} = kv_store:set(<<"user">>, Value),
    {ok, <<"user">>, Value} = kv_store:get(<<"user">>),
    teardown(ok).

set_get_list_test() ->
    setup(),
    Value = [1, 2, 3, 4, 5],
    {ok, _} = kv_store:set(<<"list">>, Value),
    {ok, <<"list">>, Value} = kv_store:get(<<"list">>),
    teardown(ok).

delete_test() ->
    setup(),
    {ok, _} = kv_store:set(<<"delete_me">>, "value"),
    {ok, <<"delete_me">>, "value"} = kv_store:get(<<"delete_me">>),
    ok = kv_store:delete(<<"delete_me">>),
    {error, not_found} = kv_store:get(<<"delete_me">>),
    teardown(ok).

delete_not_found_test() ->
    setup(),
    {error, not_found} = kv_store:delete(<<"does_not_exist">>),
    teardown(ok).

clear_all_test() ->
    setup(),
    {ok, _} = kv_store:set(<<"key1">>, "value1"),
    {ok, _} = kv_store:set(<<"key2">>, "value2"),
    {ok, <<"key1">>, "value1"} = kv_store:get(<<"key1">>),
    {ok, <<"key2">>, "value2"} = kv_store:get(<<"key2">>),
    kv_store:clear_all(),
    {error, not_found} = kv_store:get(<<"key1">>),
    {error, not_found} = kv_store:get(<<"key2">>),
    teardown(ok).

get_all_test() ->
    setup(),
    {ok, _} = kv_store:set(<<"a">>, 1),
    {ok, _} = kv_store:set(<<"b">>, 2),
    {ok, _} = kv_store:set(<<"c">>, 3),
    State = kv_store:get_all(),
    ?assertEqual(3, maps:size(State)),
    ?assertEqual(1, maps:get(<<"a">>, State)),
    ?assertEqual(2, maps:get(<<"b">>, State)),
    ?assertEqual(3, maps:get(<<"c">>, State)),
    teardown(ok).

empty_get_test() ->
    setup(),
    {error, not_found} = kv_store:get(<<"does_not_exist">>),
    teardown(ok).

invalid_key_test() ->
    setup(),
    {error, invalid_key} = kv_store:set(<<>>, "value"),
    {error, invalid_key} = kv_store:get(<<>>),
    {error, invalid_key} = kv_store:delete(<<>>),
    teardown(ok).

%% With no store running there is no table, and a read has to say so
%% rather than crash the caller -- the HTTP layer turns this into a 503.
no_store_running_test() ->
    %% teardown/1 here is a no-op, so stop the store explicitly. Exiting
    %% it normally rather than killing it matters: setup/0 used
    %% start_link/0, so a kill would follow the link into the runner.
    case whereis(kv_store) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid, normal, 5000)
    end,
    ?assertEqual(undefined, whereis(kv_store)),
    ?assertEqual({error, unavailable}, kv_store:get(<<"anything">>)),
    ?assertEqual(#{}, kv_store:get_all()).

%% /health answers with this, so it has to report the store's absence as
%% well as its presence -- the whole point is that it stops agreeing with
%% the listener once the store is gone.
ready_test() ->
    setup(),
    ?assert(kv_store:ready()),
    %% Stopped the way no_store_running_test stops it: normally, so the
    %% link back to the runner is not followed.
    case whereis(kv_store) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid, normal, 5000)
    end,
    ?assertNot(kv_store:ready()).

%% Overwrite test
overwrite_test() ->
    setup(),
    %% set/2 reports which of the two it did, so the HTTP layer can
    %% answer 201 or 200 without reading the key back first -- a
    %% read-then-write would race across two calls.
    {ok, created} = kv_store:set(<<"key">>, "first"),
    {ok, <<"key">>, "first"} = kv_store:get(<<"key">>),
    {ok, updated} = kv_store:set(<<"key">>, "second"),
    {ok, <<"key">>, "second"} = kv_store:get(<<"key">>),
    %% and a key that was deleted counts as created again
    ok = kv_store:delete(<<"key">>),
    {ok, created} = kv_store:set(<<"key">>, "third"),
    teardown(ok).