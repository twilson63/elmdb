-module(elmdb_50m_chaos_benchmark).
-export([run/0, run/1]).

-define(DEFAULT_TARGET, 50_000_000).
-define(DEFAULT_WORKERS, 10).
-define(DEFAULT_VALUE_SIZE, 100).
-define(DEFAULT_MAP_SIZE, 1024 * 1024 * 1024 * 100). % 100GB

run() ->
    run(#{}).

run(Config) ->
    Target = maps:get(target, Config, ?DEFAULT_TARGET),
    Workers = maps:get(workers, Config, ?DEFAULT_WORKERS),
    ValueSize = maps:get(value_size, Config, ?DEFAULT_VALUE_SIZE),
    MapSize = maps:get(map_size, Config, ?DEFAULT_MAP_SIZE),
    Sequential = maps:get(sequential, Config, false),
    
    io:format("=== ELMDB 50 Million Transaction Chaos Benchmark ===~n"),
    io:format("Target: ~p transactions~n", [Target]),
    io:format("Workers: ~p~n", [Workers]),
    io:format("Value size: ~p bytes~n", [ValueSize]),
    io:format("Map size: ~.1f GB~n", [MapSize / (1024 * 1024 * 1024)]),
    io:format("Key pattern: ~s~n~n", [case Sequential of true -> "sequential"; false -> "random" end]),
    
    % Clean up any existing test directory
    TestDir = "/tmp/elmdb_50m_benchmark",
    os:cmd("rm -rf " ++ TestDir),
    
    % Open environment with large map size
    {ok, Env} = elmdb:env_open(TestDir, [
        {map_size, MapSize},
        {max_dbs, 10}
    ]),
    
    % Open multiple databases for chaos testing
    Databases = lists:map(fun(I) ->
        DbName = list_to_binary("db" ++ integer_to_list(I)),
        {ok, Db} = elmdb:db_open(Env, DbName, [create]),
        {DbName, Db}
    end, lists:seq(1, 3)),
    
    % Start monitoring
    MonitorPid = spawn_link(fun() -> monitor_loop(Env, 0, erlang:system_time(second)) end),
    
    % Run the benchmark
    StartTime = erlang:system_time(millisecond),
    
    % Create worker processes
    Parent = self(),
    OpsPerWorker = Target div Workers,
    
    WorkerPids = lists:map(fun(WorkerId) ->
        spawn_link(fun() ->
            worker_process(Parent, WorkerId, OpsPerWorker, Databases, ValueSize, Sequential)
        end)
    end, lists:seq(1, Workers)),
    
    % Collect results
    Results = collect_results(WorkerPids, []),
    
    EndTime = erlang:system_time(millisecond),
    Duration = (EndTime - StartTime) / 1000,
    
    % Stop monitoring
    MonitorPid ! stop,
    
    % Calculate statistics
    TotalOps = lists:sum([Ops || {_, Ops, _} <- Results]),
    Errors = lists:flatten([Errs || {_, _, Errs} <- Results]),
    
    io:format("~n=== Final Results ===~n"),
    io:format("Duration: ~.1f seconds~n", [Duration]),
    io:format("Total operations: ~p (~.1f% of target)~n", [TotalOps, (TotalOps / Target) * 100]),
    io:format("Throughput: ~.0f ops/sec~n", [TotalOps / Duration]),
    io:format("Errors: ~p~n", [length(Errors)]),
    
    % Get final stats
    {ok, Stats} = elmdb:env_stat(Env),
    io:format("~nDatabase Statistics:~n"),
    io:format("  Entries: ~p~n", [maps:get(entries, Stats)]),
    io:format("  Map used: ~.1f%~n", [maps:get(used_percentage, Stats)]),
    io:format("  Depth: ~p~n", [maps:get(depth, Stats)]),
    io:format("  Branch pages: ~p~n", [maps:get(branch_pages, Stats)]),
    io:format("  Leaf pages: ~p~n", [maps:get(leaf_pages, Stats)]),
    io:format("  Overflow pages: ~p~n", [maps:get(overflow_pages, Stats)]),
    
    % Calculate space efficiency
    if
        TotalOps > 0 ->
            UsedBytes = maps:get(psize, Stats) * maps:get(leaf_pages, Stats),
            BytesPerOp = UsedBytes / TotalOps,
            io:format("~nSpace Efficiency:~n"),
            io:format("  Bytes per operation: ~.0f~n", [BytesPerOp]),
            io:format("  Overhead factor: ~.1fx~n", [BytesPerOp / ValueSize]);
        true ->
            ok
    end,
    
    % Clean up
    lists:foreach(fun({_, Db}) -> elmdb:db_close(Db) end, Databases),
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ TestDir),
    
    {ok, #{
        total_ops => TotalOps,
        duration => Duration,
        throughput => TotalOps / Duration,
        errors => length(Errors),
        target_percentage => (TotalOps / Target) * 100
    }}.

worker_process(Parent, WorkerId, OpsCount, Databases, ValueSize, Sequential) ->
    % Initialize random seed for this worker
    rand:seed(exsss, {WorkerId, erlang:system_time(), erlang:unique_integer()}),
    
    % Run operations with chaos patterns
    {Completed, Errors} = run_chaos_operations(WorkerId, OpsCount, Databases, ValueSize, Sequential, 0, []),
    
    Parent ! {worker_done, self(), Completed, Errors}.

run_chaos_operations(_, 0, _, _, _, Completed, Errors) ->
    {Completed, Errors};
run_chaos_operations(WorkerId, Remaining, Databases, ValueSize, Sequential, Completed, Errors) ->
    try
        % Select random database
        {DbName, Db} = lists:nth(rand:uniform(length(Databases)), Databases),
        
        % Generate key
        Key = case Sequential of
            true -> 
                Offset = (WorkerId - 1) * 5_000_000,
                <<(Offset + Completed):64>>;
            false ->
                <<(rand:uniform(1_000_000_000)):64>>
        end,
        
        % Generate value with variable size for chaos
        ActualValueSize = case rand:uniform(10) of
            1 -> ValueSize * 10;  % 10% large values
            2 -> ValueSize div 10; % 10% tiny values
            _ -> ValueSize         % 80% normal size
        end,
        Value = crypto:strong_rand_bytes(ActualValueSize),
        
        % Choose operation with chaos patterns
        case rand:uniform(100) of
            N when N =< 50 ->  % 50% regular writes (reduced from 60%)
                case rand:uniform(3) of
                    1 -> elmdb:put(Db, Key, Value);
                    2 -> elmdb:async_put(Db, Key, Value);
                    3 -> % Batch write
                        lists:foreach(fun(I) ->
                            K = <<Key/binary, I:8>>,
                            elmdb:put(Db, K, Value)
                        end, lists:seq(1, 10))
                end;
            N when N =< 65 ->  % 15% list operations
                ListKey = <<"list_", Key/binary>>,
                case rand:uniform(8) of
                    1 -> % Create list with initial values
                        Values = [crypto:strong_rand_bytes(20) || _ <- lists:seq(1, rand:uniform(10))],
                        elmdb:put(Db, ListKey, term_to_binary(Values));
                    2 -> % Append to list
                        case elmdb:get(Db, ListKey) of
                            {ok, Data} ->
                                OldList = binary_to_term(Data),
                                NewList = OldList ++ [crypto:strong_rand_bytes(20)],
                                elmdb:put(Db, ListKey, term_to_binary(NewList));
                            _ ->
                                elmdb:put(Db, ListKey, term_to_binary([crypto:strong_rand_bytes(20)]))
                        end;
                    3 -> % Prepend to list
                        case elmdb:get(Db, ListKey) of
                            {ok, Data} ->
                                OldList = binary_to_term(Data),
                                NewList = [crypto:strong_rand_bytes(20) | OldList],
                                elmdb:put(Db, ListKey, term_to_binary(NewList));
                            _ ->
                                elmdb:put(Db, ListKey, term_to_binary([crypto:strong_rand_bytes(20)]))
                        end;
                    4 -> % Pop from list
                        case elmdb:get(Db, ListKey) of
                            {ok, Data} ->
                                case binary_to_term(Data) of
                                    [_ | Rest] when Rest =/= [] ->
                                        elmdb:put(Db, ListKey, term_to_binary(Rest));
                                    _ ->
                                        elmdb:delete(Db, ListKey)
                                end;
                            _ ->
                                ok
                        end;
                    5 -> % Get list length
                        case elmdb:get(Db, ListKey) of
                            {ok, Data} ->
                                length(binary_to_term(Data));
                            _ ->
                                0
                        end;
                    6 -> % Filter list (remove elements > 10 bytes)
                        case elmdb:get(Db, ListKey) of
                            {ok, Data} ->
                                OldList = binary_to_term(Data),
                                NewList = [E || E <- OldList, byte_size(E) =< 10],
                                elmdb:put(Db, ListKey, term_to_binary(NewList));
                            _ ->
                                ok
                        end;
                    7 -> % Batch list operations in transaction
                        elmdb:txn(fun(Txn) ->
                            lists:foreach(fun(I) ->
                                LK = <<ListKey/binary, I:8>>,
                                elmdb:put(Txn, Db, LK, term_to_binary(lists:seq(1, I)))
                            end, lists:seq(1, 5))
                        end);
                    8 -> % Async list operations
                        lists:foreach(fun(I) ->
                            LK = <<ListKey/binary, I:8>>,
                            elmdb:async_put(Db, LK, term_to_binary([I, I*2, I*3]))
                        end, lists:seq(1, 10))
                end;
            N when N =< 80 ->  % 15% reads (reduced from 20%)
                case rand:uniform(2) of
                    1 -> elmdb:get(Db, Key);
                    2 -> elmdb:async_get(Db, Key)
                end;
            N when N =< 90 ->  % 10% deletes
                case rand:uniform(2) of
                    1 -> elmdb:delete(Db, Key);
                    2 -> elmdb:async_delete(Db, Key)
                end;
            N when N =< 95 ->  % 5% updates
                case elmdb:get(Db, Key) of
                    {ok, OldValue} ->
                        NewValue = <<OldValue/binary, 1>>,
                        elmdb:put(Db, Key, NewValue);
                    _ ->
                        elmdb:put(Db, Key, Value)
                end;
            _ ->  % 5% chaos operations
                case rand:uniform(7) of
                    1 -> % Cursor scan
                        elmdb:fold(Db, fun(_, _, Acc) -> 
                            case Acc of
                                10 -> {break, Acc};
                                _ -> {ok, Acc + 1}
                            end
                        end, 0);
                    2 -> % Drop and recreate
                        catch elmdb:drop(Db),
                        timer:sleep(1);
                    3 -> % Transaction with multiple ops
                        elmdb:txn(fun(Txn) ->
                            lists:foreach(fun(I) ->
                                K = <<Key/binary, I:16>>,
                                elmdb:put(Txn, Db, K, Value)
                            end, lists:seq(1, 5))
                        end);
                    4 -> % Large batch operation
                        lists:foreach(fun(I) ->
                            K = <<(rand:uniform(1_000_000)):64>>,
                            elmdb:async_put(Db, K, <<I:64>>)
                        end, lists:seq(1, 100));
                    5 -> % Sync after async burst
                        lists:foreach(fun(I) ->
                            K = <<Key/binary, I:8>>,
                            elmdb:async_put(Db, K, Value)
                        end, lists:seq(1, 20)),
                        elmdb:sync(Db);
                    6 -> % Complex list manipulation
                        ComplexKey = <<"complex_", Key/binary>>,
                        % Create nested structure
                        NestedData = [
                            {index, Completed},
                            {worker, WorkerId},
                            {lists, [lists:seq(1, rand:uniform(5)) || _ <- lists:seq(1, 3)]},
                            {binaries, [crypto:strong_rand_bytes(rand:uniform(50)) || _ <- lists:seq(1, 5)]}
                        ],
                        elmdb:put(Db, ComplexKey, term_to_binary(NestedData));
                    7 -> % Range operations on lists
                        Prefix = <<"list_", (Key):4/binary>>,
                        Count = elmdb:fold(Db, fun(K, V, Acc) ->
                            case binary:match(K, Prefix) of
                                {0, _} ->
                                    % Process list
                                    List = binary_to_term(V),
                                    {ok, Acc + length(List)};
                                _ ->
                                    {break, Acc}
                            end
                        end, 0, [{start_key, Prefix}]),
                        Count
                end
        end,
        
        % Add random delays for more realistic patterns
        case rand:uniform(100) of
            1 -> timer:sleep(10);  % 1% slow operations
            M when M =< 5 -> timer:sleep(1); % 4% minor delays
            _ -> ok
        end,
        
        run_chaos_operations(WorkerId, Remaining - 1, Databases, ValueSize, Sequential, Completed + 1, Errors)
    catch
        Error:Reason:Stacktrace ->
            NewError = {Error, Reason, Stacktrace},
            run_chaos_operations(WorkerId, Remaining - 1, Databases, ValueSize, Sequential, Completed, [NewError | Errors])
    end.

collect_results([], Results) ->
    Results;
collect_results(Workers, Results) ->
    receive
        {worker_done, Pid, Completed, Errors} ->
            NewResults = [{Pid, Completed, Errors} | Results],
            RemainingWorkers = lists:delete(Pid, Workers),
            collect_results(RemainingWorkers, NewResults)
    after 300000 ->  % 5 minute timeout
        io:format("~nTimeout waiting for workers: ~p~n", [Workers]),
        Results
    end.

monitor_loop(Env, LastCount, LastTime) ->
    receive
        stop -> ok
    after 5000 ->  % Report every 5 seconds
        {ok, Stats} = elmdb:env_stat(Env),
        Entries = maps:get(entries, Stats),
        Used = maps:get(used_percentage, Stats),
        
        Now = erlang:system_time(second),
        Duration = Now - LastTime,
        Rate = case Duration of
            0 -> 0;
            _ -> (Entries - LastCount) / Duration
        end,
        
        io:format("Progress: ~p entries, ~p% full, ~p ops/sec~n", 
                  [Entries, round(Used * 10) / 10, round(Rate)]),
        
        % Continue monitoring unless we're nearly full
        if
            Used < 95.0 ->
                monitor_loop(Env, Entries, Now);
            true ->
                io:format("~nWARNING: Database nearly full at ~p%~n", [round(Used * 10) / 10]),
                monitor_loop(Env, Entries, Now)
        end
    end.