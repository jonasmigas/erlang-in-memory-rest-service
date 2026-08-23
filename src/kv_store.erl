%%%-------------------------------------------------------------------
%%% @doc In-memory key-value store backed by a GenServer.
%%%-------------------------------------------------------------------
-module(kv_store).
-behaviour(gen_server).
-compile({no_auto_import, [get/1]}).

-export([start_link/0, set/2, get/1, delete/1, clear_all/0, get_all/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ===================================================================
%% API functions
%% ===================================================================

-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Reports whether the key was created or overwritten, so the HTTP layer
%% can answer 201 or 200 without a read-then-write across two calls --
%% which would race, and defeat the point of serialising here.
-spec set(string(), any()) -> {ok, created | updated} | {error, invalid_key}.
set("", _Value) ->
    {error, invalid_key};
set(Key, Value) ->
    gen_server:call(?MODULE, {set, Key, Value}).

-spec get(string()) -> {ok, string(), any()} | {error, not_found} | {error, invalid_key}.
get("") ->
    {error, invalid_key};
get(Key) ->
    gen_server:call(?MODULE, {get, Key}).

-spec delete(string()) -> ok | {error, not_found} | {error, invalid_key}.
delete("") ->
    {error, invalid_key};
delete(Key) ->
    gen_server:call(?MODULE, {delete, Key}).

-spec clear_all() -> ok.
clear_all() ->
    gen_server:call(?MODULE, clear_all).

-spec get_all() -> map().
get_all() ->
    gen_server:call(?MODULE, get_all).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    {ok, #{}}.

handle_call({set, Key, Value}, _From, State) ->
    Outcome = case maps:is_key(Key, State) of
        true -> updated;
        false -> created
    end,
    {reply, {ok, Outcome}, maps:put(Key, Value, State)};
handle_call({get, Key}, _From, State) ->
    case maps:find(Key, State) of
        {ok, Value} -> {reply, {ok, Key, Value}, State};
        error -> {reply, {error, not_found}, State}
    end;
handle_call({delete, Key}, _From, State) ->
    case maps:is_key(Key, State) of
        true -> {reply, ok, maps:remove(Key, State)};
        false -> {reply, {error, not_found}, State}
    end;
handle_call(clear_all, _From, _State) ->
    {reply, ok, #{}};
handle_call(get_all, _From, State) ->
    {reply, State, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.