%%%-------------------------------------------------------------------
%%% @doc The design kv_store replaced: a map held in gen_server state,
%%% read by calling the process.
%%%
%%% It exists so both designs can be measured in one VM, alternating, on
%%% the same host under the same load. Measuring them in separate runs
%%% was the mistake the first attempt made: on a laptop running Docker
%%% the same configuration varied threefold between runs, which is wider
%%% than the effect being looked for.
%%%-------------------------------------------------------------------
-module(kv_bench_map).
-behaviour(gen_server).

-export([start_link/0, stop/0, set/2, get/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid, normal, 5000)
    end.

set(Key, Value) ->
    gen_server:call(?MODULE, {set, Key, Value}).

%% The point of comparison: a read is a message to one process and a wait
%% for its reply.
get(Key) ->
    gen_server:call(?MODULE, {get, Key}).

init([]) ->
    {ok, #{}}.

handle_call({set, Key, Value}, _From, State) ->
    {reply, ok, maps:put(Key, Value, State)};
handle_call({get, Key}, _From, State) ->
    case maps:find(Key, State) of
        {ok, Value} -> {reply, {ok, Key, Value}, State};
        error -> {reply, {error, not_found}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.
