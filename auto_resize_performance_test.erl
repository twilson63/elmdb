-module(auto_resize_performance_test).
-export([run/0]).

run() ->
    io:format("=== Auto-Resize Performance Test ===~n~n"),
    
    % Test configurations
    TestConfigs = [
        {disabled, "Auto-resize DISABLED", [{auto_resize, false}]},
        {enabled, "Auto-resize ENABLED", [{auto_resize, true}, {resize_threshold, 0.75}]}
    ],
    
    % Run tests for each configuration
    Results = lists:map(fun({Name, Desc, ExtraOpts}) ->
        io:format("~n--- Testing: ~s ---~n", [Desc]),
        Result = run_performance_test(Name, ExtraOpts),
        timer:sleep(1000), % Brief pause between tests
        Result
    end, TestConfigs),
    
    % Compare results
    io:format("~n=== PERFORMANCE COMPARISON ===~n"),
    [DisabledResult, EnabledResult] = Results,
    
    compare_results(DisabledResult, EnabledResult),
    
    io:format("~n=== Test Complete ===~n").

run_performance_test(Name, ExtraOpts) ->
    Dir = "/tmp/elmdb_perf_test_" ++ atom_to_list(Name),
    os:cmd("rm -rf " ++ Dir),
    
    % Use 200MB map size to avoid resize during test (unless we want it)
    BaseOpts = [{map_size, 200 * 1024 * 1024}, {queue_size, 20000}],
    Opts = BaseOpts ++ ExtraOpts,
    
    {ok, Env} = elmdb:env_open(Dir, Opts),
    {ok, Dbi} = elmdb:db_open(Env, []),
    
    % Test parameters
    NumOps = 100000,
    NumWorkers = 10,
    ValueSize = 1024, % 1KB values
    
    % Warm up
    io:format("Warming up...~n"),
    warmup(Dbi, 1000),
    
    % Test 1: Sequential async puts
    io:format("Test 1: Sequential async puts (~p operations)...~n", [NumOps]),
    {PutTime, PutOpsPerSec} = measure_async_puts(Dbi, NumOps, ValueSize),
    
    % Test 2: Sequential async gets
    io:format("Test 2: Sequential async gets (~p operations)...~n", [NumOps]),
    {GetTime, GetOpsPerSec} = measure_async_gets(Dbi, NumOps),
    
    % Test 3: Mixed operations
    io:format("Test 3: Mixed async operations (50% put, 50% get)...~n"),
    {MixedTime, MixedOpsPerSec} = measure_mixed_ops(Dbi, NumOps),
    
    % Test 4: Concurrent operations
    io:format("Test 4: Concurrent operations (~p workers)...~n", [NumWorkers]),
    {ConcurrentTime, ConcurrentOpsPerSec} = measure_concurrent_ops(Dbi, NumWorkers, NumOps div NumWorkers),
    
    % Test 5: Synchronous operations
    io:format("Test 5: Synchronous put operations (10k ops)...~n"),
    {SyncTime, SyncOpsPerSec} = measure_sync_puts(Dbi, 10000, ValueSize),
    
    % Get final stats
    {ok, Stats} = elmdb:env_stat(Env),
    FinalUsage = maps:get(used_percentage, Stats),
    
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    #{
        name => Name,
        async_put => {PutTime, PutOpsPerSec},
        async_get => {GetTime, GetOpsPerSec},
        mixed_ops => {MixedTime, MixedOpsPerSec},
        concurrent => {ConcurrentTime, ConcurrentOpsPerSec},
        sync_put => {SyncTime, SyncOpsPerSec},
        final_usage => FinalUsage
    }.

warmup(Dbi, N) ->
    lists:foreach(fun(I) ->
        K = <<"warmup", I:32>>,
        V = <<I:64>>,
        elmdb:put(Dbi, K, V)
    end, lists:seq(1, N)).

measure_async_puts(Dbi, N, ValueSize) ->
    Value = binary:copy(<<0>>, ValueSize),
    Start = erlang:monotonic_time(),
    
    lists:foreach(fun(I) ->
        Key = <<I:64>>,
        ok = elmdb:async_put(Dbi, Key, Value)
    end, lists:seq(1, N)),
    
    End = erlang:monotonic_time(),
    Time = erlang:convert_time_unit(End - Start, native, microsecond) / 1000000,
    OpsPerSec = N / Time,
    io:format("  Time: ~p seconds, ~p ops/sec~n", [Time, round(OpsPerSec)]),
    {Time, OpsPerSec}.

measure_async_gets(Dbi, N) ->
    Start = erlang:monotonic_time(),
    
    lists:foreach(fun(I) ->
        Key = <<I:64>>,
        case elmdb:async_get(Dbi, Key) of
            {ok, _} -> ok;
            not_found -> ok;
            Error -> throw({get_error, Error})
        end
    end, lists:seq(1, N)),
    
    End = erlang:monotonic_time(),
    Time = erlang:convert_time_unit(End - Start, native, microsecond) / 1000000,
    OpsPerSec = N / Time,
    io:format("  Time: ~p seconds, ~p ops/sec~n", [Time, round(OpsPerSec)]),
    {Time, OpsPerSec}.

measure_mixed_ops(Dbi, N) ->
    Start = erlang:monotonic_time(),
    
    lists:foreach(fun(I) ->
        case I rem 2 of
            0 ->
                Key = <<(1000000 + I):64>>,
                Val = <<I:64>>,
                ok = elmdb:async_put(Dbi, Key, Val);
            1 ->
                Key = <<(I div 2):64>>,
                case elmdb:async_get(Dbi, Key) of
                    {ok, _} -> ok;
                    not_found -> ok;
                    Error -> throw({get_error, Error})
                end
        end
    end, lists:seq(1, N)),
    
    End = erlang:monotonic_time(),
    Time = erlang:convert_time_unit(End - Start, native, microsecond) / 1000000,
    OpsPerSec = N / Time,
    io:format("  Time: ~p seconds, ~p ops/sec~n", [Time, round(OpsPerSec)]),
    {Time, OpsPerSec}.

measure_concurrent_ops(Dbi, NumWorkers, OpsPerWorker) ->
    Parent = self(),
    Start = erlang:monotonic_time(),
    
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            lists:foreach(fun(I) ->
                Key = <<(W * 1000000 + I):64>>,
                Val = <<I:64>>,
                ok = elmdb:async_put(Dbi, Key, Val)
            end, lists:seq(1, OpsPerWorker)),
            Parent ! {done, self()}
        end)
    end, lists:seq(1, NumWorkers)),
    
    lists:foreach(fun(Worker) ->
        receive
            {done, Worker} -> ok
        after 30000 ->
            throw({timeout, Worker})
        end
    end, Workers),
    
    End = erlang:monotonic_time(),
    Time = erlang:convert_time_unit(End - Start, native, microsecond) / 1000000,
    TotalOps = NumWorkers * OpsPerWorker,
    OpsPerSec = TotalOps / Time,
    io:format("  Time: ~p seconds, ~p ops/sec~n", [Time, round(OpsPerSec)]),
    {Time, OpsPerSec}.

measure_sync_puts(Dbi, N, ValueSize) ->
    Value = binary:copy(<<1>>, ValueSize),
    Start = erlang:monotonic_time(),
    
    lists:foreach(fun(I) ->
        Key = <<"sync", I:32>>,
        ok = elmdb:put(Dbi, Key, Value)
    end, lists:seq(1, N)),
    
    End = erlang:monotonic_time(),
    Time = erlang:convert_time_unit(End - Start, native, microsecond) / 1000000,
    OpsPerSec = N / Time,
    io:format("  Time: ~p seconds, ~p ops/sec~n", [Time, round(OpsPerSec)]),
    {Time, OpsPerSec}.

compare_results(#{name := disabled} = DisabledResult, #{name := enabled} = EnabledResult) ->
    io:format("~n"),
    io:format("Operation          | Disabled     | Enabled      | Impact~n"),
    io:format("-------------------|--------------|--------------|--------~n"),
    
    compare_op("Async PUT", 
               maps:get(async_put, DisabledResult),
               maps:get(async_put, EnabledResult)),
    
    compare_op("Async GET",
               maps:get(async_get, DisabledResult),
               maps:get(async_get, EnabledResult)),
    
    compare_op("Mixed Ops",
               maps:get(mixed_ops, DisabledResult),
               maps:get(mixed_ops, EnabledResult)),
    
    compare_op("Concurrent",
               maps:get(concurrent, DisabledResult),
               maps:get(concurrent, EnabledResult)),
    
    compare_op("Sync PUT",
               maps:get(sync_put, DisabledResult),
               maps:get(sync_put, EnabledResult)),
    
    io:format("~n"),
    io:format("Final DB usage: ~p%~n", [round(maps:get(final_usage, EnabledResult))]).

compare_op(Name, {_, DisabledOps}, {_, EnabledOps}) ->
    Impact = ((EnabledOps - DisabledOps) / DisabledOps) * 100,
    Color = if
        Impact < -5 -> "\e[31m"; % Red for >5% slower
        Impact > 5 -> "\e[32m";  % Green for >5% faster
        true -> "\e[33m"         % Yellow for within 5%
    end,
    io:format("~-18s | ~12w | ~12w | ~s~6w%~s~n", 
              [Name, round(DisabledOps), round(EnabledOps), Color, round(Impact), "\e[0m"]).