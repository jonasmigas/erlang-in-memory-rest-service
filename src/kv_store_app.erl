%%%-------------------------------------------------------------------
%%% @doc Application entry point for the KV Store service.
%%%-------------------------------------------------------------------
-module(kv_store_app).
-behaviour(application).

-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

-spec start(application:start_type(), any()) -> {ok, pid()} | {error, any()}.
start(_StartType, _StartArgs) ->
    kv_store_sup:start_link().

-spec stop(any()) -> ok.
stop(_State) ->
    ok.