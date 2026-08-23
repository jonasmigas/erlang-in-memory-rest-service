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
    ok = kv_store:set("test_key", "test_value"),
    {ok, "test_key", "test_value"} = kv_store:get("test_key"),
    teardown(ok).

set_get_integer_test() ->
    setup(),
    ok = kv_store:set("number", 42),
    {ok, "number", 42} = kv_store:get("number"),
    teardown(ok).

set_get_map_test() ->
    setup(),
    Value = #{name => <<"João">>, age => 30},
    ok = kv_store:set("user", Value),
    {ok, "user", Value} = kv_store:get("user"),
    teardown(ok).

set_get_list_test() ->
    setup(),
    Value = [1, 2, 3, 4, 5],
    ok = kv_store:set("list", Value),
    {ok, "list", Value} = kv_store:get("list"),
    teardown(ok).

delete_test() ->
    setup(),
    ok = kv_store:set("delete_me", "value"),
    {ok, "delete_me", "value"} = kv_store:get("delete_me"),
    ok = kv_store:delete("delete_me"),
    {error, not_found} = kv_store:get("delete_me"),
    teardown(ok).

delete_not_found_test() ->
    setup(),
    {error, not_found} = kv_store:delete("does_not_exist"),
    teardown(ok).

clear_all_test() ->
    setup(),
    ok = kv_store:set("key1", "value1"),
    ok = kv_store:set("key2", "value2"),
    {ok, "key1", "value1"} = kv_store:get("key1"),
    {ok, "key2", "value2"} = kv_store:get("key2"),
    kv_store:clear_all(),
    {error, not_found} = kv_store:get("key1"),
    {error, not_found} = kv_store:get("key2"),
    teardown(ok).

get_all_test() ->
    setup(),
    ok = kv_store:set("a", 1),
    ok = kv_store:set("b", 2),
    ok = kv_store:set("c", 3),
    State = kv_store:get_all(),
    ?assertEqual(3, maps:size(State)),
    ?assertEqual(1, maps:get("a", State)),
    ?assertEqual(2, maps:get("b", State)),
    ?assertEqual(3, maps:get("c", State)),
    teardown(ok).

empty_get_test() ->
    setup(),
    {error, not_found} = kv_store:get("does_not_exist"),
    teardown(ok).

invalid_key_test() ->
    setup(),
    {error, invalid_key} = kv_store:set("", "value"),
    {error, invalid_key} = kv_store:get(""),
    {error, invalid_key} = kv_store:delete(""),
    teardown(ok).

%% Overwrite test
overwrite_test() ->
    setup(),
    ok = kv_store:set("key", "first"),
    {ok, "key", "first"} = kv_store:get("key"),
    ok = kv_store:set("key", "second"),
    {ok, "key", "second"} = kv_store:get("key"),
    teardown(ok).