%%%-------------------------------------------------------------------
%%% @doc In-memory key-value store backed by a GenServer.
%%%-------------------------------------------------------------------
%%% Keys are binaries throughout. They arrive from cowboy as binaries
%%% and leave through jsx as binaries, so converting to a list in
%%% between only cost work and gave the two representations a chance to
%%% disagree.
-module(kv_store).
-behaviour(gen_server).
-compile({no_auto_import, [get/1]}).

-export([start_link/0, set/2, get/1, delete/1, clear_all/0, get_all/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TABLE, kv_store_table).
-define(DEFAULT_CALL_TIMEOUT, 5000).

%% Overridable so a caller that must answer quickly -- or a test -- can
%% bound how long it waits on a busy store.
call_timeout() ->
    application:get_env(kv_store, call_timeout, ?DEFAULT_CALL_TIMEOUT).

%% ===================================================================
%% API functions
%% ===================================================================

-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Reports whether the key was created or overwritten, so the HTTP layer
%% can answer 201 or 200 without a read-then-write across two calls --
%% which would race, and defeat the point of serialising here.
-spec set(binary(), any()) -> {ok, created | updated} | {error, invalid_key}.
set(<<>>, _Value) ->
    {error, invalid_key};
set(Key, Value) ->
    gen_server:call(?MODULE, {set, Key, Value}, call_timeout()).

%% Read in the calling process, straight from ETS, rather than sending a
%% message to the store and waiting.
%%
%% The reason is availability, not speed. A gen_server handles one
%% message at a time, so every read queued behind every other request and
%% behind every write: one slow or wedged caller stalled all of them, and
%% a busy store turned reads into timeouts. Reading from the table
%% removes reads from that queue entirely -- kv_http_tests proves it,
%% by suspending the store process and watching reads keep answering
%% while writes correctly report 503.
%%
%% It should also let reads use more than one core, since ETS reads run
%% concurrently while a process cannot. That is the standard reason to
%% do this, but it is not measured here: throughput on this setup varied
%% by 3x between identical runs, which is not a basis for a number.
%%
%% What it does NOT fix: a large value is still copied to the caller, so
%% one client pulling a big entry still costs the whole node CPU and
%% allocator bandwidth. Measured, that degrades small-key reads about
%% the same either way.
%%
%% The table is `protected` and owned by the gen_server, so writes stay
%% serialised there and this cannot race with them; it also means the
%% table dies with the store, which keeps the existing durability
%% semantics rather than quietly changing them.
-spec get(binary()) ->
    {ok, binary(), any()} | {error, not_found | invalid_key | unavailable}.
get(<<>>) ->
    {error, invalid_key};
get(Key) ->
    try ets:lookup(?TABLE, Key) of
        [{Key, Value}] -> {ok, Key, Value};
        [] -> {error, not_found}
    catch
        %% No table means no owner: the store is down or restarting.
        error:badarg -> {error, unavailable}
    end.

-spec delete(binary()) -> ok | {error, not_found} | {error, invalid_key}.
delete(<<>>) ->
    {error, invalid_key};
delete(Key) ->
    gen_server:call(?MODULE, {delete, Key}, call_timeout()).

-spec clear_all() -> ok.
clear_all() ->
    gen_server:call(?MODULE, clear_all, call_timeout()).

-spec get_all() -> map().
get_all() ->
    try maps:from_list(ets:tab2list(?TABLE))
    catch error:badarg -> #{}
    end.

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    %% protected: this process is the only writer, everyone reads. Owned
    %% here so the data dies with the store exactly as the map did.
    ?TABLE = ets:new(?TABLE, [named_table, protected, {read_concurrency, true}]),
    {ok, ?TABLE}.

%% Writes stay here. Serialising them is what makes created-vs-updated a
%% single atomic decision -- ets:insert_new/2 answers it in the same
%% operation that does the write, and no other writer can be in flight.
handle_call({set, Key, Value}, _From, T) ->
    Outcome = case ets:insert_new(T, {Key, Value}) of
        true ->
            created;
        false ->
            true = ets:insert(T, {Key, Value}),
            updated
    end,
    {reply, {ok, Outcome}, T};
%% ets:take/2 removes the entry and reports what was there in one
%% operation, so telling a delete from a miss does not depend on nothing
%% happening between a member/2 and a delete/2. It only ever ran here, with
%% one writer, so the old pair was safe -- but it was safe by virtue of the
%% serialisation rather than on its own, which is exactly the difference
%% insert_new/2 already avoids on the write side.
handle_call({delete, Key}, _From, T) ->
    case ets:take(T, Key) of
        [_Entry] -> {reply, ok, T};
        [] -> {reply, {error, not_found}, T}
    end;
handle_call(clear_all, _From, T) ->
    true = ets:delete_all_objects(T),
    {reply, ok, T}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.