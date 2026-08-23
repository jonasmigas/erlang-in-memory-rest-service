%%%-------------------------------------------------------------------
%%% @doc Root supervisor for the KV Store application.
%%% Manages the GenServer and HTTP server.
%%%-------------------------------------------------------------------
-module(kv_store_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(STRATEGY, one_for_one).

%% ===================================================================
%% API functions
%% ===================================================================

-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    %% Child 1: The KV Store GenServer
    StoreChild = #{
        id => kv_store,
        start => {kv_store, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [kv_store]
    },

    %% Child 2: the cowboy listener. kv_http:child_spec/0 returns ranch's
    %% own spec so the listener is supervised here rather than by ranch_sup.
    HttpChild = kv_http:child_spec(),

    Children = [StoreChild, HttpChild],

    %% One-for-one: if one child dies, only that child is restarted
    {ok, {{?STRATEGY, 5, 10}, Children}}.