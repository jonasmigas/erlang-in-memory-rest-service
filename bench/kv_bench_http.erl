%%%-------------------------------------------------------------------
%%% @doc Load through the HTTP stack, which every other measurement here
%%% skips.
%%%
%%% kv_bench calls kv_store directly and reports what the store can do.
%%% That is a real number and it is not the one an operator is asked for:
%%% between a client and the table sit socket reads, request parsing,
%%% routing, JSON decoding and encoding, and a socket write. This measures
%%% the whole path and exists so the difference is a figure rather than an
%%% assumption.
%%%
%%% Load is generated in-process over persistent connections rather than
%%% by spawning a client per request. An earlier attempt with one curl per
%%% request measured 439 req/s, which was the cost of starting curl on
%%% Windows and said nothing whatever about the server.
%%%-------------------------------------------------------------------
-module(kv_bench_http).

-export([main/0, main/1]).

-define(KEY, <<"http_bench_key">>).
-define(BODY, <<"{\"value\": \"a small value, so the transport is what is measured\"}">>).

%% Sized so the whole run is under a minute. The first draft asked for
%% 2000 requests over 5 rounds and two verbs at up to 64 connections --
%% about 1.7 million requests, which is not a hang but looks exactly like
%% one from outside.
main() ->
    main(#{requests => 500, rounds => 3, connections => [1, 4, 16, 64]}).

main(#{requests := N, rounds := Rounds, connections := Levels}) ->
    {ok, _} = application:ensure_all_started(kv_store),
    Port = port(),
    {ok, created} = kv_store:set(?KEY, <<"seeded">>),

    io:format("~nThrough HTTP: cowboy, routing, JSON, sockets~n"),
    io:format("~p schedulers, port ~p, ~p requests per connection, median of ~p rounds~n~n",
              [erlang:system_info(schedulers_online), Port, N, Rounds]),

    %% Warm the path so round one does not pay for first-call work.
    _ = run(get, Port, 4, 200),

    io:format("~-6s ~14s ~14s~n", ["conns", "GET req/s", "PUT req/s"]),
    lists:foreach(
      fun(C) ->
              Gets = median([run(get, Port, C, N) || _ <- lists:seq(1, Rounds)]),
              Puts = median([run(put, Port, C, N) || _ <- lists:seq(1, Rounds)]),
              io:format("~-6w ~14w ~14w~n", [C, Gets, Puts])
      end, Levels),
    halt(0).

port() ->
    {ok, Port} = application:get_env(kv_store, port),
    Port.

%% Each connection is opened once and reused for every request on it, so
%% what is measured is request handling and not TCP setup.
run(Verb, Port, Conns, N) ->
    Parent = self(),
    Start = erlang:monotonic_time(microsecond),
    %% spawn_monitor, not spawn: a worker that dies mid-request would
    %% otherwise leave the parent waiting on a message that is never
    %% coming, and the benchmark would look like a hang rather than a
    %% failure. The timeout covers a worker that is stuck rather than dead.
    Pids = [element(1, spawn_monitor(
                         fun() ->
                                 {ok, Sock} = gen_tcp:connect(
                                                {127, 0, 0, 1}, Port,
                                                [binary, {active, false},
                                                 {packet, raw}]),
                                 ok = drive(Sock, request(Verb, W), N),
                                 gen_tcp:close(Sock),
                                 Parent ! {done, self()}
                         end)) || W <- lists:seq(1, Conns)],
    ok = await(Pids),
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    round((N * Conns) / (Elapsed / 1000000)).

await([]) ->
    ok;
await(Pids) ->
    receive
        {done, Pid} ->
            await(lists:delete(Pid, Pids));
        {'DOWN', _Ref, process, _Pid, normal} ->
            await(Pids);
        {'DOWN', _Ref, process, Pid, Reason} ->
            error({load_worker_died, Pid, Reason})
    after 60000 ->
        error({load_workers_stuck, length(Pids)})
    end.

drive(_Sock, _Req, 0) ->
    ok;
drive(Sock, Req, N) ->
    ok = gen_tcp:send(Sock, Req),
    ok = recv_response(Sock),
    drive(Sock, Req, N - 1).

%% Parse just enough to consume exactly one response and leave the socket
%% positioned for the next: status line and headers via the VM's own HTTP
%% packet mode, then content-length bytes of body.
recv_response(Sock) ->
    ok = inet:setopts(Sock, [{packet, http_bin}]),
    {ok, {http_response, _, _Status, _}} = gen_tcp:recv(Sock, 0, 10000),
    Length = headers(Sock, 0),
    ok = inet:setopts(Sock, [{packet, raw}]),
    case Length of
        0 -> ok;
        _ -> {ok, _} = gen_tcp:recv(Sock, Length, 10000), ok
    end.

headers(Sock, Length) ->
    case gen_tcp:recv(Sock, 0, 10000) of
        {ok, http_eoh} ->
            Length;
        {ok, {http_header, _, 'Content-Length', _, Value}} ->
            headers(Sock, binary_to_integer(Value));
        {ok, {http_header, _, _, _, _}} ->
            headers(Sock, Length)
    end.

%% GET reads one seeded key; PUT writes a key of its own, so writers do
%% not pile onto a single entry.
request(get, _W) ->
    [<<"GET /store/">>, ?KEY, <<" HTTP/1.1\r\n">>,
     <<"Host: 127.0.0.1\r\n\r\n">>];
request(put, W) ->
    Key = <<"http_w", (integer_to_binary(W))/binary>>,
    [<<"PUT /store/">>, Key, <<" HTTP/1.1\r\n">>,
     <<"Host: 127.0.0.1\r\n">>,
     <<"Content-Type: application/json\r\n">>,
     <<"Content-Length: ">>, integer_to_binary(byte_size(?BODY)), <<"\r\n\r\n">>,
     ?BODY].

median(Xs) ->
    Sorted = lists:sort(Xs),
    lists:nth((length(Sorted) div 2) + 1, Sorted).
