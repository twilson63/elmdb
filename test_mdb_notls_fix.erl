-module(test_mdb_notls_fix).
-export([run/0]).

run() ->
    io:format("=== Testing MDB_NOTLS Fix ===~n~n"),
    
    Dir = "/tmp/elmdb_notls_test",
    os:cmd("rm -rf " ++ Dir),
    
    % Open environment (now without MDB_NOTLS flag)
    {ok, Env} = elmdb:env_open(Dir, [{map_size, 100 * 1024 * 1024}]),
    {ok, Dbi} = elmdb:db_open(Env, []),
    
    % Test 1: High concurrency mixed operations
    io:format("Test 1: High concurrency mixed sync/async operations...~n"),
    test_mixed_operations(Dbi),
    
    % Test 2: Concurrent synchronous reads
    io:format("~nTest 2: Concurrent synchronous reads...~n"),
    test_concurrent_reads(Dbi),
    
    % Test 3: Stress test with all operation types
    io:format("~nTest 3: Stress test with all operations...~n"),
    stress_test_all_ops(Dbi),
    
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    io:format("~n=== All Tests Passed! ===~n").

test_mixed_operations(Dbi) ->
    NumWorkers = 100,
    OpsPerWorker = 1000,
    
    % Pre-populate some data
    lists:foreach(fun(I) ->
        K = <<I:64>>,
        V = <<I:64>>,
        elmdb:put(Dbi, K, V)
    end, lists:seq(1, 1000)),
    
    Parent = self(),
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            lists:foreach(fun(I) ->
                Op = rand:uniform(4),
                K = <<(rand:uniform(1000)):64>>,
                case Op of
                    1 -> % Sync put
                        elmdb:put(Dbi, K, <<W:32, I:32>>);
                    2 -> % Sync get
                        elmdb:get(Dbi, K);
                    3 -> % Async put
                        elmdb:async_put(Dbi, K, <<W:32, I:32>>);
                    4 -> % Async get
                        elmdb:async_get(Dbi, K)
                end
            end, lists:seq(1, OpsPerWorker)),
            Parent ! {done, self()}
        end)
    end, lists:seq(1, NumWorkers)),
    
    wait_for_workers(Workers),
    io:format("  ✓ Completed ~p operations with ~p workers~n", 
              [NumWorkers * OpsPerWorker, NumWorkers]).

test_concurrent_reads(Dbi) ->
    NumReaders = 200,
    ReadsPerWorker = 100,
    
    Parent = self(),
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            lists:foreach(fun(_) ->
                K = <<(rand:uniform(1000)):64>>,
                case elmdb:get(Dbi, K) of
                    {ok, _} -> ok;
                    not_found -> ok;
                    Error -> Parent ! {error, self(), Error}
                end
            end, lists:seq(1, ReadsPerWorker)),
            Parent ! {done, self()}
        end)
    end, lists:seq(1, NumReaders)),
    
    wait_for_workers(Workers),
    io:format("  ✓ Completed ~p concurrent reads with ~p readers~n", 
              [NumReaders * ReadsPerWorker, NumReaders]).

stress_test_all_ops(Dbi) ->
    NumWorkers = 50,
    Duration = 5000, % 5 seconds
    
    Parent = self(),
    StartTime = erlang:monotonic_time(millisecond),
    
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            worker_loop(Dbi, W, StartTime, Duration, Parent, 0)
        end)
    end, lists:seq(1, NumWorkers)),
    
    TotalOps = wait_for_workers_with_count(Workers, 0),
    
    ElapsedSecs = Duration / 1000,
    OpsPerSec = TotalOps / ElapsedSecs,
    io:format("  ✓ Completed ~p operations in ~.1f seconds (~.0f ops/sec)~n", 
              [TotalOps, ElapsedSecs, OpsPerSec]).

worker_loop(Dbi, W, StartTime, Duration, Parent, Count) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - StartTime > Duration of
        true ->
            Parent ! {done, self(), Count};
        false ->
            % Random operation
            Op = rand:uniform(6),
            K = <<(W * 10000 + rand:uniform(1000)):64>>,
            V = <<Now:64, W:32>>,
            
            case Op of
                1 -> elmdb:put(Dbi, K, V);
                2 -> elmdb:get(Dbi, K);
                3 -> elmdb:delete(Dbi, K);
                4 -> elmdb:async_put(Dbi, K, V);
                5 -> elmdb:async_get(Dbi, K);
                6 -> elmdb:async_delete(Dbi, K)
            end,
            
            worker_loop(Dbi, W, StartTime, Duration, Parent, Count + 1)
    end.

wait_for_workers(Workers) ->
    lists:foreach(fun(Worker) ->
        receive
            {done, Worker} -> ok;
            {error, Worker, Error} -> 
                throw({worker_error, Worker, Error})
        after 30000 ->
            throw({timeout, Worker})
        end
    end, Workers).

wait_for_workers_with_count(Workers, Total) ->
    lists:foldl(fun(Worker, Acc) ->
        receive
            {done, Worker, Count} -> Acc + Count;
            {error, Worker, Error} -> 
                throw({worker_error, Worker, Error})
        after 30000 ->
            throw({timeout, Worker})
        end
    end, Total, Workers).