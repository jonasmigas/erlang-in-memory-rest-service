#!/usr/bin/env escript
%%! -noshell
%%%-------------------------------------------------------------------
%%% Walks the brief end to end against a running service and shows every
%%% answer, so the acceptance criteria are watched rather than inferred
%%% from a table.
%%%
%%% Written in Erlang rather than shell because the image has no curl,
%%% and busybox wget cannot send a PUT or a request body at all -- the
%%% first attempt at this used it and every call failed silently. escript
%%% is already in the image, and httpc gives the method, body and status
%%% code without argument-parsing gymnastics.
%%%
%%% Runs inside the container and reaches the service by its compose name,
%%% which keeps the only-docker-on-the-host promise the Makefile makes.
%%%-------------------------------------------------------------------

-define(BASE, "http://kv_store:8080").

main(_) ->
    {ok, _} = application:ensure_all_started(inets),

    rule(),
    io:format(" The brief: set data on a key, get it back, clear it, get again.~n"),
    rule(),

    %% The service may have been left running by an earlier demo, so
    %% clear Key1 before claiming anything about a key that never held
    %% data. The result is deliberately ignored.
    _ = httpc:request(delete, {?BASE ++ "/store/Key1", []}, [], []),

    step("1. Getting Key1 before anything is stored"),
    Never = call(get, "/store/Key1", none),

    step("2. Setting Data1 on Key1"),
    call(put, "/store/Key1", "{\"value\": \"Data1\"}"),

    step("3. Getting Key1 -- the brief asks for BOTH the key and the data"),
    Read = call(get, "/store/Key1", none),

    step("4. Clearing Key1"),
    call(delete, "/store/Key1", none),

    step("5. Getting Key1 again -- must read as if never set"),
    Cleared = call(get, "/store/Key1", none),

    io:format("~n"),
    rule(),
    verdict(Read, Cleared, Never),
    rule().

%% The two checks the brief actually specifies, asserted rather than left
%% for the reader to eyeball.
%%
%% The comparison is between the same key before it held anything and
%% after it was cleared. An earlier version compared Key1 against a
%% different key that was never written, which fails for a reason that
%% is not a defect: each 404 echoes its own key name, so the bodies
%% differ correctly.
verdict({200, ReadBody}, {ClearedStatus, ClearedBody}, {NeverStatus, NeverBody}) ->
    case {string:find(ReadBody, "\"key\""), string:find(ReadBody, "\"value\"")} of
        {nomatch, _} -> io:format(" FAIL: the read did not return the key~n");
        {_, nomatch} -> io:format(" FAIL: the read did not return the data~n");
        _ -> io:format(" A successful read returns both the key and the data.~n")
    end,
    case {ClearedStatus, ClearedBody} =:= {NeverStatus, NeverBody} of
        true ->
            io:format(" Key1 after clearing answers exactly as it did before it~n"),
            io:format(" ever held data, which is what the brief requires.~n");
        false ->
            io:format(" FAIL: before and after answered differently:~n"),
            io:format("   before:  ~p ~s~n   cleared: ~p ~s~n",
                      [NeverStatus, NeverBody, ClearedStatus, ClearedBody])
    end;
verdict(Read, _, _) ->
    io:format(" FAIL: reading a key just written did not answer 200: ~p~n", [Read]).

call(Method, Path, Body) ->
    Url = ?BASE ++ Path,
    io:format("  $ ~s ~s~s~n",
              [string:uppercase(atom_to_list(Method)), Path,
               case Body of none -> ""; _ -> "  " ++ Body end]),
    Request = case Body of
                  none -> {Url, []};
                  _ -> {Url, [], "application/json", Body}
              end,
    {ok, {{_, Status, Reason}, _Headers, Received}} =
        httpc:request(Method, Request, [], []),
    io:format("    ~p ~s~n", [Status, Reason]),
    case Received of
        [] -> ok;
        _ -> io:format("    ~s~n", [Received])
    end,
    {Status, Received}.

step(Text) ->
    io:format("~n~s~n", [Text]).

rule() ->
    io:format("==================================================================~n").
