%%%-------------------------------------------------------------------
%%% @doc Compares reading from ETS against reading through a gen_server.
%%%
%%% Method, and why it is this method:
%%%
%%% Both designs run in one VM and are measured alternately inside each
%%% round, so a slow moment on the host lands on both. What is reported
%%% is the ratio between them, which survives that noise; absolute ops/s
%%% on a laptop running Docker does not, and the first attempt at this
%%% measurement was thrown away for exactly that reason.
%%%
%%% Rounds are summarised by median rather than mean, so one descheduled
%%% round cannot carry the result, and the spread is printed so a reader
%%% can see how much to trust the middle.
%%%
%%% The interesting number is not throughput, it is how throughput
%%% responds to concurrency. A gen_server handles one message at a time,
%%% so its total should stay flat as readers are added. ETS reads run in
%%% the caller, so theirs should climb until the cores run out.
%%%-------------------------------------------------------------------
-module(kv_bench).

-export([main/0, main/1, capacity/0]).

-define(KEY, <<"bench_key">>).
-define(VALUE, <<"a small value, so the mechanism is what is measured">>).

main() ->
    main(#{reads => 20000, rounds => 7, concurrency => [1, 2, 4, 8]}).

main(#{reads := Reads, rounds := Rounds, concurrency := Levels}) ->
    io:format("~nkv_store read path: ETS vs gen_server~n"),
    io:format("~p schedulers, ~p reads per process, ~p rounds, median of ratios~n~n",
              [erlang:system_info(schedulers_online), Reads, Rounds]),

    {ok, _} = kv_store:start_link(),
    {ok, _} = kv_bench_map:start_link(),
    {ok, created} = kv_store:set(?KEY, ?VALUE),
    ok = kv_bench_map:set(?KEY, ?VALUE),

    %% Warm both paths so neither pays for first-call work in round 1.
    _ = time_run(fun read_ets/1, 2, 2000),
    _ = time_run(fun read_map/1, 2, 2000),

    %% Measure once. Reporting the table and the scaling from separate
    %% passes let them contradict each other -- a run where the table
    %% climbed to 8M ops/s printed "2 processes: 0.63x" underneath it,
    %% because that line came from a different set of measurements.
    Measured = [{C, rounds(C, Reads, Rounds)} || C <- Levels],

    io:format("~-6s ~12s ~12s ~9s   ~s~n",
              ["procs", "ETS ops/s", "gen ops/s", "ratio", "ETS spread (min-max)"]),
    lists:foreach(fun report/1, Measured),

    io:format("~nScaling from 1 process, same measurements:~n"),
    scaling(Measured),

    contention(Rounds),
    capacity(),

    kv_bench_map:stop(),
    ok.

report({C, {Ets, Map, Ratios}}) ->
    io:format("~-6w ~12w ~12w ~9s   ~w - ~w~n",
              [C, median(Ets), median(Map),
               io_lib:format("~.2fx", [median_f(Ratios)]),
               lists:min(Ets), lists:max(Ets)]).

%% One round measures both designs back to back, so whatever the host is
%% doing at that moment is done to both of them.
rounds(C, Reads, Rounds) ->
    Results = [begin
                   E = time_run(fun read_ets/1, C, Reads),
                   M = time_run(fun read_map/1, C, Reads),
                   {E, M, E / M}
               end || _ <- lists:seq(1, Rounds)],
    {[E || {E, _, _} <- Results],
     [M || {_, M, _} <- Results],
     [R || {_, _, R} <- Results]}.

scaling(Measured) ->
    Medians = [{C, {median(E), median(M)}} || {C, {E, M, _}} <- Measured],
    [{_, {Ets1, Map1}} | _] = Medians,
    lists:foreach(
      fun({C, {E, M}}) ->
              io:format("  ~w process(es): ETS ~.2fx   gen_server ~.2fx~n",
                        [C, E / Ets1, M / Map1])
      end, Medians).

%% What one entry costs, measured rather than estimated, because
%% "how many fit in a node" is the question that decides whether one node
%% is the answer at all.
%%
%% Two numbers, because they answer different questions. ETS reports what
%% the table itself holds; a value over 64 bytes is a refcounted binary
%% living on the shared heap, so the table only holds a pointer to it and
%% ets:info/2 alone would flatter the result badly. The VM total catches
%% the binary as well, and that is the one that fills a machine.
capacity() ->
    io:format("~nMemory per entry, ~p-byte keys~n", [byte_size(cap_key(1))]),
    io:format("  ~8s ~12s ~12s ~16s~n",
              ["value", "ets b/entry", "vm b/entry", "entries per GiB"]),
    lists:foreach(fun cap_row/1, [16, 64, 256, 1024]).

cap_row(ValueSize) ->
    ok = kv_store:clear_all(),
    settle(),
    EtsBefore = ets_bytes(),
    VmBefore = erlang:memory(total),
    N = 20000,
    Filler = binary:copy(<<"v">>, ValueSize),
    lists:foreach(
      fun(I) ->
              %% Each value is its own binary. Storing one shared binary
              %% N times would measure a pointer N times and report a
              %% number no real workload could reproduce.
              Value = <<(integer_to_binary(I))/binary, Filler/binary>>,
              {ok, _} = kv_store:set(cap_key(I), Value)
      end, lists:seq(1, N)),
    settle(),
    EtsPer = (ets_bytes() - EtsBefore) / N,
    VmPer = (erlang:memory(total) - VmBefore) / N,
    io:format("  ~8w ~12w ~12w ~16w~n",
              [ValueSize, round(EtsPer), round(VmPer),
               round((1024 * 1024 * 1024) / erlang:max(VmPer, 1))]).

%% A value over 64 bytes is a refcounted binary on a shared heap, and
%% dropping it from the table does not reclaim it there and then.
%% erlang:garbage_collect/0 collects only the calling process, so the
%% previous row's garbage was still counted against the next row's
%% baseline: one run had 256-byte values reporting the same cost per
%% entry as 16-byte ones, which is the tell. Collect everywhere and wait
%% for the total to stop moving before taking a reading.
settle() ->
    collect_all(),
    settle(erlang:memory(total), 20).

settle(_Prev, 0) ->
    ok;
settle(Prev, N) ->
    timer:sleep(50),
    collect_all(),
    Now = erlang:memory(total),
    case abs(Now - Prev) < 65536 of
        true -> ok;
        false -> settle(Now, N - 1)
    end.

collect_all() ->
    lists:foreach(fun(P) -> erlang:garbage_collect(P) end, processes()).

cap_key(I) ->
    <<"player:", (integer_to_binary(1000000 + I))/binary>>.

ets_bytes() ->
    ets:info(kv_store_table, memory) * erlang:system_info(wordsize).

%% Does one client reading a large value hurt everybody else, and does
%% reading outside the process change that? The copy still happens either
%% way -- the question is whether it happens somewhere that blocks others.
contention(Rounds) ->
    Big = binary:copy(<<"x">>, 4 * 1024 * 1024),
    {ok, _} = kv_store:set(<<"big">>, Big),
    ok = kv_bench_map:set(<<"big">>, Big),
    N = 4000,
    Pairs = [{retained(fun read_ets/1, fun() -> kv_store:get(<<"big">>) end, N),
              retained(fun read_map/1, fun() -> kv_bench_map:get(<<"big">>) end, N)}
             || _ <- lists:seq(1, Rounds)],
    io:format("~nSmall-key reads while one client pulls a 4MB value~n"),
    io:format("  (percent of throughput retained, median of ~p rounds)~n", [Rounds]),
    io:format("  ETS        : ~w%~n", [median([E || {E, _} <- Pairs])]),
    io:format("  gen_server : ~w%~n", [median([M || {_, M} <- Pairs])]).

%% Measure small-key reads alone, then again with a big-value reader
%% looping alongside, and report what fraction survived.
retained(Read, PullBig, N) ->
    Alone = time_run(Read, 1, N),
    Parent = self(),
    Hog = spawn(fun Loop() ->
                        receive stop -> Parent ! stopped
                        after 0 -> PullBig(), Loop()
                        end
                end),
    timer:sleep(200),
    Under = time_run(Read, 1, N),
    Hog ! stop,
    receive stopped -> ok after 5000 -> ok end,
    round(Under * 100 / Alone).

%% Spawn C readers, each doing Reads lookups, and report ops/s across all
%% of them. Wall clock, because the question is what the whole node did.
time_run(Read, C, Reads) ->
    Parent = self(),
    Start = erlang:monotonic_time(microsecond),
    Pids = [spawn(fun() -> Read(Reads), Parent ! {done, self()} end)
            || _ <- lists:seq(1, C)],
    lists:foreach(fun(Pid) -> receive {done, Pid} -> ok end end, Pids),
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    round((Reads * C) / (Elapsed / 1000000)).

read_ets(N) ->
    lists:foreach(fun(_) -> kv_store:get(?KEY) end, lists:seq(1, N)).

read_map(N) ->
    lists:foreach(fun(_) -> kv_bench_map:get(?KEY) end, lists:seq(1, N)).

median(Xs) ->
    Sorted = lists:sort(Xs),
    lists:nth((length(Sorted) div 2) + 1, Sorted).

median_f(Xs) ->
    Sorted = lists:sort(Xs),
    lists:nth((length(Sorted) div 2) + 1, Sorted).
