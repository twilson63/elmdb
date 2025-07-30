-module(run_quick_benchmark).
-export([run/0]).

run() ->
    io:format("=== ELMDB Quick Benchmark with List Operations ===~n~n"),
    
    Dir = "/tmp/elmdb_quick_benchmark",
    os:cmd("rm -rf " ++ Dir),
    
    {ok, Env} = elmdb:env_open(Dir, [{map_size, 1024 * 1024 * 1024}]), % 1GB
    {ok, Db} = elmdb:db_open(Env, []),
    
    StartTime = erlang:system_time(millisecond),
    
    % Test 1: Sequential writes
    io:format("Test 1: Sequential writes...~n"),
    T1Start = erlang:system_time(millisecond),
    lists:foreach(fun(I) ->
        Key = <<I:64>>,
        Value = crypto:strong_rand_bytes(100),
        elmdb:put(Db, Key, Value)
    end, lists:seq(1, 10000)),
    T1End = erlang:system_time(millisecond),
    T1Ops = 10000 / ((T1End - T1Start) / 1000),
    io:format("  Sequential writes: ~p ops/sec~n", [round(T1Ops)]),
    
    % Test 2: Random writes
    io:format("~nTest 2: Random writes...~n"),
    T2Start = erlang:system_time(millisecond),
    lists:foreach(fun(_) ->
        Key = <<(rand:uniform(1000000)):64>>,
        Value = crypto:strong_rand_bytes(100),
        elmdb:put(Db, Key, Value)
    end, lists:seq(1, 10000)),
    T2End = erlang:system_time(millisecond),
    T2Ops = 10000 / ((T2End - T2Start) / 1000),
    io:format("  Random writes: ~p ops/sec~n", [round(T2Ops)]),
    
    % Test 3: List operations
    io:format("~nTest 3: List operations...~n"),
    T3Start = erlang:system_time(millisecond),
    lists:foreach(fun(I) ->
        ListKey = <<"list_", I:32>>,
        List = lists:seq(1, 100),
        elmdb:put(Db, ListKey, term_to_binary(List))
    end, lists:seq(1, 1000)),
    T3End = erlang:system_time(millisecond),
    T3Ops = 1000 / ((T3End - T3Start) / 1000),
    io:format("  List writes: ~p ops/sec~n", [round(T3Ops)]),
    
    % Test 4: Concurrent operations
    io:format("~nTest 4: Concurrent operations...~n"),
    T4Start = erlang:system_time(millisecond),
    Parent = self(),
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            lists:foreach(fun(I) ->
                Key = <<W:32, I:32>>,
                Value = <<W:32, I:64>>,
                elmdb:put(Db, Key, Value)
            end, lists:seq(1, 1000)),
            Parent ! {done, self()}
        end)
    end, lists:seq(1, 10)),
    
    lists:foreach(fun(Worker) ->
        receive {done, Worker} -> ok end
    end, Workers),
    T4End = erlang:system_time(millisecond),
    T4Ops = 10000 / ((T4End - T4Start) / 1000),
    io:format("  Concurrent writes: ~p ops/sec~n", [round(T4Ops)]),
    
    % Test 5: Mixed operations with lists
    io:format("~nTest 5: Mixed operations with lists...~n"),
    T5Start = erlang:system_time(millisecond),
    lists:foreach(fun(I) ->
        case I rem 5 of
            0 -> % Write list
                Key = <<"mixed_list_", I:32>>,
                List = [rand:uniform(1000) || _ <- lists:seq(1, 20)],
                elmdb:put(Db, Key, term_to_binary(List));
            1 -> % Read and append to list
                Key = <<"mixed_list_", ((I div 5) * 5):32>>,
                case elmdb:get(Db, Key) of
                    {ok, Data} ->
                        List = binary_to_term(Data),
                        NewList = List ++ [I],
                        elmdb:put(Db, Key, term_to_binary(NewList));
                    _ ->
                        elmdb:put(Db, Key, term_to_binary([I]))
                end;
            2 -> % Regular write
                elmdb:put(Db, <<I:64>>, <<I:128>>);
            3 -> % Read
                elmdb:get(Db, <<(I - 2):64>>);
            4 -> % Async write
                elmdb:async_put(Db, <<"async_", I:64>>, <<I:256>>)
        end
    end, lists:seq(1, 10000)),
    T5End = erlang:system_time(millisecond),
    T5Ops = 10000 / ((T5End - T5Start) / 1000),
    io:format("  Mixed operations: ~p ops/sec~n", [round(T5Ops)]),
    
    % Get final stats
    {ok, Stats} = elmdb:env_stat(Env),
    io:format("~nFinal Statistics:~n"),
    io:format("  Total entries: ~p~n", [maps:get(entries, Stats)]),
    io:format("  Database used: ~p%~n", [round(maps:get(used_percentage, Stats) * 10) / 10]),
    
    EndTime = erlang:system_time(millisecond),
    TotalDuration = (EndTime - StartTime) / 1000,
    io:format("~nTotal benchmark duration: ~p seconds~n", [round(TotalDuration * 10) / 10]),
    
    % Clean up
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    io:format("~n=== Benchmark Complete ===~n"),
    
    % Return results for recording
    #{
        commit_hash => os:cmd("git rev-parse HEAD") -- "\n",
        date => calendar:local_time(),
        results => #{
            sequential_writes => round(T1Ops),
            random_writes => round(T2Ops),
            list_writes => round(T3Ops),
            concurrent_writes => round(T4Ops),
            mixed_operations => round(T5Ops),
            total_entries => maps:get(entries, Stats)
        }
    }.