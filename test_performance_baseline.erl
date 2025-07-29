-module(test_performance_baseline).
-export([run/0]).

%% Performance baseline test for elmdb
%% Use this to verify performance after changes

run() ->
    io:format("=== elmdb Performance Baseline Test ===~n~n"),
    
    Dir = "/tmp/elmdb_perf_baseline",
    os:cmd("rm -rf " ++ Dir),
    {ok, Env} = elmdb:env_open(Dir, [{map_size, 1073741824}]), % 1GB
    {ok, Dbi} = elmdb:db_open(Env, []),
    
    % Test 1: Sequential writes
    io:format("Test 1: Sequential writes~n"),
    T1 = erlang:monotonic_time(microsecond),
    lists:foreach(fun(N) ->
        elmdb:put(Dbi, <<N:64>>, <<N:512>>)
    end, lists:seq(1, 10000)),
    T2 = erlang:monotonic_time(microsecond),
    SeqWriteTime = T2 - T1,
    io:format("  10,000 sequential writes: ~p µs (~p ops/sec)~n", 
              [SeqWriteTime, 10000 * 1000000 div SeqWriteTime]),
    
    % Test 2: Random reads
    io:format("~nTest 2: Random reads~n"),
    T3 = erlang:monotonic_time(microsecond),
    lists:foreach(fun(_) ->
        N = rand:uniform(10000),
        elmdb:get(Dbi, <<N:64>>)
    end, lists:seq(1, 10000)),
    T4 = erlang:monotonic_time(microsecond),
    RandomReadTime = T4 - T3,
    io:format("  10,000 random reads: ~p µs (~p ops/sec)~n",
              [RandomReadTime, 10000 * 1000000 div RandomReadTime]),
    
    % Test 3: Concurrent async operations
    io:format("~nTest 3: Concurrent async operations~n"),
    Self = self(),
    Workers = 100,
    OpsPerWorker = 1000,
    
    T5 = erlang:monotonic_time(microsecond),
    lists:foreach(fun(W) ->
        spawn(fun() ->
            lists:foreach(fun(Op) ->
                Key = <<(W * 10000 + Op):64>>,
                Val = <<W:32, Op:32>>,
                elmdb:async_put(Dbi, Key, Val)
            end, lists:seq(1, OpsPerWorker)),
            Self ! {done, W}
        end)
    end, lists:seq(1, Workers)),
    
    lists:foreach(fun(W) ->
        receive {done, W} -> ok after 30000 -> timeout end
    end, lists:seq(1, Workers)),
    T6 = erlang:monotonic_time(microsecond),
    AsyncTime = T6 - T5,
    TotalOps = Workers * OpsPerWorker,
    io:format("  ~p async puts (~p workers): ~p µs (~p ops/sec)~n",
              [TotalOps, Workers, AsyncTime, TotalOps * 1000000 div AsyncTime]),
    
    % Test 4: High concurrency stress (10k writers)
    io:format("~nTest 4: High concurrency (10,000 writers)~n"),
    T7 = erlang:monotonic_time(microsecond),
    lists:foreach(fun(W) ->
        spawn(fun() ->
            Key = <<W:64>>,
            Val = <<W:512>>,
            elmdb:async_put(Dbi, Key, Val),
            Self ! {extreme_done, W}
        end)
    end, lists:seq(1, 10000)),
    
    lists:foreach(fun(W) ->
        receive {extreme_done, W} -> ok after 30000 -> timeout end
    end, lists:seq(1, 10000)),
    T8 = erlang:monotonic_time(microsecond),
    ExtremeTime = T8 - T7,
    io:format("  10,000 concurrent writes: ~p µs (~p ops/sec)~n",
              [ExtremeTime, 10000 * 1000000 div ExtremeTime]),
    
    % Expected baseline: ~16,000 ops/sec for 10k concurrent
    ExpectedBaseline = 16000,
    ActualPerf = 10000 * 1000000 div ExtremeTime,
    Percentage = ActualPerf * 100 div ExpectedBaseline,
    
    io:format("~n=== Performance Summary ===~n"),
    io:format("Expected baseline: ~p ops/sec~n", [ExpectedBaseline]),
    io:format("Actual performance: ~p ops/sec (~p%)~n", [ActualPerf, Percentage]),
    
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    ok.