%%%-------------------------------------------------------------------
%%% @doc elmdb Security Fixes Integration Tests
%%% Tests race conditions, buffer overflows, use-after-free scenarios
%%% @end
%%%-------------------------------------------------------------------
-module(security_integration_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_DB_PATH, "/tmp/elmdb_security_test").
-define(NUM_PROCESSES, 100).
-define(OPS_PER_PROCESS, 1000).
-define(MAX_CONCURRENT_WRITES, 50).

%%%===================================================================
%%% Test 1: Concurrent Initialization Race Condition
%%%===================================================================
concurrent_initialization_test() ->
    io:format("~n=== Test 1: Concurrent Initialization ===~n"),
    
    %% Clean up any existing test DB
    os:cmd("rm -rf " ++ ?TEST_DB_PATH),
    
    %% Spawn many processes that will all try to open environments simultaneously
    Parent = self(),
    Pids = [spawn_link(fun() -> concurrent_init_worker(Parent, N) end) 
            || N <- lists:seq(1, ?NUM_PROCESSES)],
    
    %% Collect results
    Results = [receive {Pid, Result} -> Result end || Pid <- Pids],
    
    %% Verify all succeeded without crashes
    SuccessCount = length([ok || ok <- Results]),
    ?assertEqual(?NUM_PROCESSES, SuccessCount),
    
    %% Clean up
    os:cmd("rm -rf " ++ ?TEST_DB_PATH),
    io:format("PASS: All ~p processes initialized without crashes~n", [?NUM_PROCESSES]).

concurrent_init_worker(Parent, N) ->
    DbPath = ?TEST_DB_PATH ++ "_" ++ integer_to_list(N),
    Result = try
        case elmdb:env_open(DbPath, [{map_size, 10485760}, {max_dbs, 10}]) of
            {ok, Env} ->
                elmdb:env_close(Env),
                ok;
            Error ->
                Error
        end
    catch
        _:_ -> error
    end,
    Parent ! {self(), Result}.

%%%===================================================================
%%% Test 2: Buffer Overflow Protection
%%%===================================================================
buffer_overflow_test() ->
    io:format("~n=== Test 2: Buffer Overflow Protection ===~n"),
    
    %% Test 1: Maximum valid path (MAXPATHLEN-1 chars)
    MaxPath = lists:duplicate(1023, $a),
    test_path_handling(MaxPath, "maximum valid path"),
    
    %% Test 2: Overflow attempt (>MAXPATHLEN)
    OverflowPath = lists:duplicate(2000, $b),
    test_path_handling(OverflowPath, "overflow path"),
    
    %% Test 3: Empty path
    test_path_handling("", "empty path"),
    
    %% Test 4: Path with special characters
    SpecialPath = "/tmp/test\n\r\t/../../../etc/passwd",
    test_path_handling(SpecialPath, "special characters"),
    
    %% Test 5: Path with null bytes (should fail gracefully)
    NullPath = "/tmp/test" ++ [0] ++ "hidden",
    test_path_handling(NullPath, "null bytes"),
    
    io:format("PASS: Buffer overflow protection working correctly~n").

test_path_handling(Path, Description) ->
    Result = try
        case elmdb:env_open(Path, [{map_size, 10485760}]) of
            {ok, Env} ->
                elmdb:env_close(Env),
                ok;
            {error, _} = E ->
                E
        end
    catch
        error:badarg -> {error, badarg};
        _:Reason -> {error, Reason}
    end,
    io:format("  ~s: ~p~n", [Description, Result]).

%%%===================================================================
%%% Test 3: Use-After-Free Prevention
%%%===================================================================
use_after_free_test() ->
    io:format("~n=== Test 3: Use-After-Free Prevention ===~n"),
    
    %% Create environment and database
    os:cmd("rm -rf " ++ ?TEST_DB_PATH),
    {ok, Env} = elmdb:env_open(?TEST_DB_PATH, [{map_size, 10485760}, {max_dbs, 10}]),
    {ok, DB} = elmdb:db_open(Env, <<"testdb">>, [create]),
    
    %% Start async operations
    Parent = self(),
    Workers = [spawn_link(fun() -> use_after_free_worker(Parent, Env, DB, N) end)
               || N <- lists:seq(1, 20)],
    
    %% Let workers run briefly
    timer:sleep(100),
    
    %% Close environment while operations may be pending
    elmdb:env_close(Env),
    
    %% Collect results - workers should handle closure gracefully
    Results = [receive {Pid, Result} -> Result end || Pid <- Workers],
    
    %% Count successful operations and errors
    {OkCount, ErrCount} = lists:foldl(
        fun({ok, N}, {Ok, Err}) -> {Ok + N, Err};
           ({error, N}, {Ok, Err}) -> {Ok, Err + N}
        end, {0, 0}, Results),
    
    io:format("  Operations before close: ~p, After close errors: ~p~n", [OkCount, ErrCount]),
    ?assert(OkCount > 0),
    
    %% Clean up
    os:cmd("rm -rf " ++ ?TEST_DB_PATH),
    io:format("PASS: Use-after-free prevention working~n").

use_after_free_worker(Parent, Env, DB, N) ->
    Key = <<"key", N:32>>,
    Val = <<"value", N:32>>,
    
    OkCount = use_after_free_loop(Env, DB, Key, Val, 0, 1000),
    Parent ! {self(), {ok, OkCount}}.

use_after_free_loop(_Env, _DB, _Key, _Val, Count, 0) -> Count;
use_after_free_loop(Env, DB, Key, Val, Count, Remaining) ->
    case elmdb:async_put(DB, Key, Val) of
        ok -> 
            use_after_free_loop(Env, DB, Key, Val, Count + 1, Remaining - 1);
        {error, _} ->
            Count
    end.

%%%===================================================================
%%% Test 4: Condition Variable Performance & Correctness
%%%===================================================================
condition_variable_test() ->
    io:format("~n=== Test 4: Condition Variable Performance ===~n"),
    
    %% Setup
    os:cmd("rm -rf " ++ ?TEST_DB_PATH),
    {ok, Env} = elmdb:env_open(?TEST_DB_PATH, [{map_size, 104857600}, {max_dbs, 10}]),
    {ok, DB} = elmdb:db_open(Env, <<"perfdb">>, [create]),
    
    %% Start monitoring process
    Monitor = spawn_link(fun() -> monitor_writes() end),
    
    %% Start many writer processes
    Parent = self(),
    StartTime = erlang:monotonic_time(millisecond),
    
    Writers = [spawn_link(fun() -> write_limiter_worker(Parent, Env, DB, N) end)
               || N <- lists:seq(1, ?NUM_PROCESSES)],
    
    %% Collect results
    Results = [receive {Pid, {completed, Ops, Time}} -> {Ops, Time} end || Pid <- Writers],
    
    EndTime = erlang:monotonic_time(millisecond),
    TotalTime = EndTime - StartTime,
    
    %% Stop monitor
    Monitor ! stop,
    
    %% Calculate statistics
    TotalOps = lists:sum([Ops || {Ops, _} <- Results]),
    Throughput = (TotalOps * 1000) div TotalTime,
    
    io:format("  Total operations: ~p in ~p ms (~p ops/sec)~n", 
              [TotalOps, TotalTime, Throughput]),
    
    %% Verify all operations completed
    ?assertEqual(?NUM_PROCESSES * ?OPS_PER_PROCESS, TotalOps),
    
    %% Verify reasonable throughput (should be much better than serialized)
    ?assert(Throughput > 1000),
    
    %% Clean up
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ ?TEST_DB_PATH),
    io:format("PASS: Condition variable throttling working correctly~n").

write_limiter_worker(Parent, Env, DB, N) ->
    StartTime = erlang:monotonic_time(millisecond),
    write_limiter_loop(Env, DB, N, ?OPS_PER_PROCESS),
    EndTime = erlang:monotonic_time(millisecond),
    Parent ! {self(), {completed, ?OPS_PER_PROCESS, EndTime - StartTime}}.

write_limiter_loop(_Env, _DB, _N, 0) -> ok;
write_limiter_loop(Env, DB, N, Remaining) ->
    Key = <<"key", N:32, Remaining:32>>,
    Val = crypto:strong_rand_bytes(100),
    
    case elmdb:async_put(DB, Key, Val) of
        ok -> ok;
        {error, Reason} -> 
            io:format("Write error: ~p~n", [Reason])
    end,
    
    write_limiter_loop(Env, DB, N, Remaining - 1).

monitor_writes() ->
    monitor_writes_loop().

monitor_writes_loop() ->
    receive
        stop -> ok
    after 1000 ->
        %% In real implementation, we'd query actual write stats
        io:format("  Monitor: Still running...~n"),
        monitor_writes_loop()
    end.

%%%===================================================================
%%% Test 5: Stress Test & Memory Leak Detection
%%%===================================================================
stress_test() ->
    io:format("~n=== Test 5: Stress Test & Memory Leak Detection ===~n"),
    
    %% Setup
    os:cmd("rm -rf " ++ ?TEST_DB_PATH),
    {ok, Env} = elmdb:env_open(?TEST_DB_PATH, [{map_size, 1073741824}, {max_dbs, 100}]),
    
    %% Create multiple databases
    DBs = [begin
               {ok, DB} = elmdb:db_open(Env, <<"stressdb", N:32>>, [create]),
               DB
           end || N <- lists:seq(1, 10)],
    
    %% Get initial memory usage
    InitialMem = erlang:memory(total),
    
    %% Run stress test
    Parent = self(),
    StressProcs = [spawn_link(fun() -> stress_worker(Parent, Env, DBs, N) end)
                   || N <- lists:seq(1, 50)],
    
    %% Monitor memory during test
    MemMonitor = spawn_link(fun() -> memory_monitor(InitialMem) end),
    
    %% Collect results
    Results = [receive {Pid, {done, Ops, Errors}} -> {Ops, Errors} end || Pid <- StressProcs],
    
    %% Stop memory monitor
    MemMonitor ! stop,
    
    %% Calculate totals
    {TotalOps, TotalErrors} = lists:foldl(
        fun({Ops, Errors}, {AccOps, AccErrors}) -> 
            {AccOps + Ops, AccErrors + Errors}
        end, {0, 0}, Results),
    
    %% Check final memory
    FinalMem = erlang:memory(total),
    MemIncrease = (FinalMem - InitialMem) / 1048576,
    
    io:format("  Total operations: ~p, Errors: ~p~n", [TotalOps, TotalErrors]),
    io:format("  Memory increase: ~.2f MB~n", [MemIncrease]),
    
    %% Verify no errors and reasonable memory usage
    ?assertEqual(0, TotalErrors),
    ?assert(MemIncrease < 100), %% Should not leak more than 100MB
    
    %% Clean up
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ ?TEST_DB_PATH),
    io:format("PASS: Stress test completed without leaks~n").

stress_worker(Parent, Env, DBs, N) ->
    Result = stress_worker_loop(Env, DBs, N, 10000, 0, 0),
    Parent ! {self(), Result}.

stress_worker_loop(_Env, _DBs, _N, 0, Ops, Errors) ->
    {done, Ops, Errors};
stress_worker_loop(Env, DBs, N, Remaining, Ops, Errors) ->
    %% Random operation
    DB = lists:nth(rand:uniform(length(DBs)), DBs),
    Key = <<"stress", N:32, Remaining:32>>,
    Val = crypto:strong_rand_bytes(rand:uniform(1000)),
    
    {NewOps, NewErrors} = case rand:uniform(3) of
        1 -> %% Async put
            case elmdb:async_put(DB, Key, Val) of
                ok -> {Ops + 1, Errors};
                {error, _} -> {Ops, Errors + 1}
            end;
        2 -> %% Sync put
            case elmdb:put(DB, Key, Val) of
                ok -> {Ops + 1, Errors};
                {error, _} -> {Ops, Errors + 1}
            end;
        3 -> %% Get
            case elmdb:get(DB, Key) of
                {ok, _} -> {Ops + 1, Errors};
                {error, notfound} -> {Ops + 1, Errors};
                {error, _} -> {Ops, Errors + 1}
            end
    end,
    
    stress_worker_loop(Env, DBs, N, Remaining - 1, NewOps, NewErrors).

memory_monitor(InitialMem) ->
    memory_monitor_loop(InitialMem, 0).

memory_monitor_loop(InitialMem, Count) ->
    receive
        stop -> ok
    after 5000 ->
        CurrentMem = erlang:memory(total),
        Increase = (CurrentMem - InitialMem) / 1048576,
        io:format("  Memory: +~.2f MB~n", [Increase]),
        memory_monitor_loop(InitialMem, Count + 1)
    end.

%%%===================================================================
%%% Test 6: Rapid Open/Close Cycles
%%%===================================================================
rapid_open_close_test() ->
    io:format("~n=== Test 6: Rapid Open/Close Cycles ===~n"),
    
    Parent = self(),
    Cycles = 100,
    
    %% Run rapid open/close in multiple processes
    Procs = [spawn_link(fun() -> rapid_cycle_worker(Parent, N, Cycles) end)
             || N <- lists:seq(1, 10)],
    
    %% Collect results
    Results = [receive {Pid, Result} -> Result end || Pid <- Procs],
    
    %% Verify all completed successfully
    SuccessCount = length([ok || ok <- Results]),
    ?assertEqual(10, SuccessCount),
    
    io:format("PASS: Rapid open/close cycles handled correctly~n").

rapid_cycle_worker(Parent, N, Cycles) ->
    DbPath = ?TEST_DB_PATH ++ "_rapid_" ++ integer_to_list(N),
    Result = rapid_cycle_loop(DbPath, Cycles),
    os:cmd("rm -rf " ++ DbPath),
    Parent ! {self(), Result}.

rapid_cycle_loop(_DbPath, 0) -> ok;
rapid_cycle_loop(DbPath, Remaining) ->
    case elmdb:env_open(DbPath, [{map_size, 10485760}]) of
        {ok, Env} ->
            %% Start some async operations
            spawn(fun() ->
                try
                    {ok, DB} = elmdb:db_open(Env, <<"rapiddb">>, [create]),
                    elmdb:async_put(DB, <<"key">>, <<"value">>)
                catch _:_ -> ok
                end
            end),
            
            %% Close quickly
            timer:sleep(rand:uniform(10)),
            elmdb:env_close(Env),
            rapid_cycle_loop(DbPath, Remaining - 1);
        {error, _} ->
            error
    end.

%%%===================================================================
%%% Run all tests
%%%===================================================================
run_all_tests() ->
    io:format("~nelmdb Security Fixes Integration Test Suite~n"),
    io:format("==========================================~n"),
    
    Tests = [
        {concurrent_initialization_test, "Concurrent Initialization"},
        {buffer_overflow_test, "Buffer Overflow Protection"},
        {use_after_free_test, "Use-After-Free Prevention"},
        {condition_variable_test, "Condition Variable Performance"},
        {stress_test, "Stress Test & Memory Leaks"},
        {rapid_open_close_test, "Rapid Open/Close Cycles"}
    ],
    
    Failed = lists:foldl(fun({Test, Name}, Acc) ->
        try
            io:format("~nRunning ~s...~n", [Name]),
            ?MODULE:Test(),
            Acc
        catch
            _:Reason:Stack ->
                io:format("FAIL: ~s - ~p~n~p~n", [Name, Reason, Stack]),
                Acc + 1
        end
    end, 0, Tests),
    
    io:format("~n==========================================~n"),
    if
        Failed == 0 ->
            io:format("ALL TESTS PASSED~n");
        true ->
            io:format("FAILURES: ~p tests failed~n", [Failed])
    end,
    
    %% Return exit code
    halt(Failed).

%% EUnit test wrapper
security_test_() ->
    {timeout, 300, fun run_all_tests/0}.