%%%-------------------------------------------------------------------
%%% @doc Counters for the HTTP and store paths, rendered for Prometheus.
%%%
%%% Counting happens in the request process, against a public ETS table
%%% with write_concurrency. Sending a message to a metrics process would
%%% put back the queue the read path was deliberately moved out of, and
%%% it would do it at precisely the wrong moment: the busier the system,
%%% the longer that queue, so the numbers would degrade exactly when they
%%% are being read to find out what is wrong.
%%%
%%% A counter that cannot be written is not a reason to fail a request,
%%% so every update is guarded and every failure is dropped.
%%%-------------------------------------------------------------------
-module(kv_metrics).
-behaviour(gen_server).

-export([start_link/0, child_spec/0, request/2, store_op/2, render/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(TABLE, kv_metrics_table).

%% ===================================================================
%% API
%% ===================================================================

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% One HTTP response, by method and status.
-spec request(binary(), non_neg_integer()) -> ok.
request(Method, Status) ->
    bump({requests_total, Method, Status}).

%% One store operation, by what was asked and what came back.
-spec store_op(atom(), atom()) -> ok.
store_op(Op, Result) ->
    bump({store_ops_total, Op, Result}).

%% Prometheus text exposition. Gauges are read at scrape time rather than
%% tracked, so they cannot drift from the thing they describe.
-spec render() -> iodata().
render() ->
    Counters = counters(),
    [
     help(<<"kv_http_requests_total">>, <<"HTTP responses by method and status">>, <<"counter">>),
     [render_line(<<"kv_http_requests_total">>,
                  [{<<"method">>, M}, {<<"status">>, integer_to_binary(S)}], V)
      || {{requests_total, M, S}, V} <- Counters],

     help(<<"kv_store_operations_total">>, <<"Store operations by result">>, <<"counter">>),
     [render_line(<<"kv_store_operations_total">>,
                  [{<<"op">>, atom_to_binary(Op)}, {<<"result">>, atom_to_binary(R)}], V)
      || {{store_ops_total, Op, R}, V} <- Counters],

     help(<<"kv_store_entries">>, <<"Keys currently held">>, <<"gauge">>),
     render_line(<<"kv_store_entries">>, [], gauge(size)),

     help(<<"kv_store_memory_bytes">>, <<"Bytes held by the store table">>, <<"gauge">>),
     render_line(<<"kv_store_memory_bytes">>, [], gauge(memory))
    ].

%% ===================================================================
%% Internal
%% ===================================================================

bump(Key) ->
    try
        _ = ets:update_counter(?TABLE, Key, {2, 1}, {Key, 0}),
        ok
    catch
        %% No table yet, or it went with its owner. Losing a count is
        %% not worth failing the request that produced it.
        error:badarg -> ok
    end.

counters() ->
    try lists:sort(ets:tab2list(?TABLE))
    catch error:badarg -> []
    end.

gauge(What) ->
    case ets:info(kv_store_table, What) of
        undefined -> 0;
        N when What =:= memory -> N * erlang:system_info(wordsize);
        N -> N
    end.

help(Name, Help, Type) ->
    [<<"# HELP ">>, Name, <<" ">>, Help, <<"\n">>,
     <<"# TYPE ">>, Name, <<" ">>, Type, <<"\n">>].

render_line(Name, [], Value) ->
    [Name, <<" ">>, integer_to_binary(Value), <<"\n">>];
render_line(Name, Labels, Value) ->
    Rendered = lists:join(<<",">>,
                          [[K, <<"=\"">>, V, <<"\"">>] || {K, V} <- Labels]),
    [Name, <<"{">>, Rendered, <<"} ">>, integer_to_binary(Value), <<"\n">>].

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([]) ->
    %% public, because the request processes write to it directly.
    ?TABLE = ets:new(?TABLE, [named_table, public, {write_concurrency, true}]),
    {ok, ?TABLE}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
