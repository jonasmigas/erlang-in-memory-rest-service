%%%-------------------------------------------------------------------
%%% @doc Unit tests for the KV Store.
%%%-------------------------------------------------------------------
-module(kv_store_tests).
-include_lib("eunit/include/eunit.hrl").

%% Setup/teardown
setup() ->
    kv_store:start_link(),
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

%% The store is bounded, so a client cannot walk it into a node's memory
%% one write at a time. The ceiling is in bytes rather than entries: with
%% values capped at 1 MiB by the HTTP layer, a million-entry ceiling would
%% still permit a terabyte.
quota_test() ->
    setup(),
    ok = application:set_env(kv_store, max_bytes, 4000),
    try
        ?assertEqual({ok, created}, kv_store:set(<<"q1">>, binary:copy(<<"s">>, 100))),

        %% A value past the ceiling on its own is refused...
        ?assertEqual({error, store_full},
                     kv_store:set(<<"q2">>, binary:copy(<<"b">>, 5000))),
        %% ...and the refusal leaves nothing behind, which an insert
        %% followed by an undo would not guarantee.
        ?assertEqual({error, not_found}, kv_store:get(<<"q2">>)),

        %% Replacing an entry with a smaller one always fits.
        ?assertEqual({ok, updated}, kv_store:set(<<"q1">>, <<"tiny">>)),

        %% Filling most of the budget leaves no room for a second big one.
        ?assertEqual({ok, created}, kv_store:set(<<"q3">>, binary:copy(<<"x">>, 3000))),
        ?assertEqual({error, store_full},
                     kv_store:set(<<"q4">>, binary:copy(<<"x">>, 3000))),

        %% Replacing that entry with a smaller one is accepted even though
        %% the same bytes arriving as a new key would not be -- the write
        %% frees what it replaces.
        ?assertEqual({ok, updated}, kv_store:set(<<"q3">>, binary:copy(<<"x">>, 2000))),

        %% Deleting refunds the budget, so the write that just failed now
        %% succeeds. This is the accounting that drifts if a refund is
        %% missed anywhere.
        ok = kv_store:delete(<<"q3">>),
        ?assertEqual({ok, created}, kv_store:set(<<"q4">>, binary:copy(<<"x">>, 3000))),

        %% And clearing returns the whole budget.
        ok = kv_store:clear_all(),
        ?assertEqual({ok, created}, kv_store:set(<<"q5">>, binary:copy(<<"x">>, 3000)))
    after
        application:unset_env(kv_store, max_bytes)
    end.
