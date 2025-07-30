-module(test_5gb_threshold).
-export([run/0, run/1]).

run() ->
    run([]).

run(Flags) ->
    io:format("=== Testing 5GB Threshold Issue ===~n"),
    io:format("Flags: ~p~n~n", [Flags]),
    
    Dir = "/tmp/elmdb_5gb_test",
    os:cmd("rm -rf " ++ Dir),
    
    % Start with 10GB map size to ensure we can reach 5GB
    MapSize = 10 * 1024 * 1024 * 1024,
    OpenOpts = [{map_size, MapSize} | Flags],
    
    io:format("Opening environment with map_size: ~.1f GB~n", [MapSize / (1024*1024*1024)]),
    {ok, Env} = elmdb:env_open(Dir, OpenOpts),
    {ok, Db} = elmdb:db_open(Env, []),
    
    % Start monitoring in background
    MonitorPid = spawn_link(fun() -> monitor_db_size(Env) end),
    
    % Write data until we exceed 5GB
    io:format("~nStarting writes to exceed 5GB threshold...~n"),
    
    Parent = self(),
    NumWorkers = 10,
    TargetPerWorker = 1000000, % 1M operations per worker
    
    Workers = lists:map(fun(W) ->
        spawn_link(fun() ->
            worker_process(Db, W, TargetPerWorker, Parent)
        end)
    end, lists:seq(1, NumWorkers)),
    
    % Collect results
    Results = collect_results(Workers, []),
    
    % Stop monitor
    MonitorPid ! stop,
    
    % Get final stats
    {ok, Stats} = elmdb:env_stat(Env),
    FinalSizeGB = (maps:get(psize, Stats) * maps:get(branch_pages, Stats) + 
                   maps:get(psize, Stats) * maps:get(leaf_pages, Stats) + 
                   maps:get(psize, Stats) * maps:get(overflow_pages, Stats)) / (1024*1024*1024),
    
    io:format("~n=== Final Results ===~n"),
    io:format("Database size: ~.2f GB~n", [FinalSizeGB]),
    io:format("Total entries: ~p~n", [maps:get(entries, Stats)]),
    io:format("Map used: ~.1f%~n", [maps:get(used_percentage, Stats) * 100]),
    
    % Check for errors
    Errors = [E || {error, _, E} <- Results],
    case Errors of
        [] ->
            io:format("~n✓ SUCCESS: No mdb_page_touch assertions!~n");
        _ ->
            io:format("~n✗ FAILED with ~p errors:~n", [length(Errors)]),
            lists:foreach(fun(E) ->
                io:format("  - ~p~n", [E])
            end, lists:sublist(Errors, 5))
    end,
    
    % Clean up
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    io:format("~n=== Test Complete ===~n"),
    {ok, #{
        final_size_gb => FinalSizeGB,
        total_entries => maps:get(entries, Stats),
        errors => length(Errors),
        flags => Flags
    }}.

worker_process(Db, WorkerId, TargetOps, Parent) ->
    try
        write_loop(Db, WorkerId, 0, TargetOps),
        Parent ! {done, self(), TargetOps}
    catch
        Error:Reason:Stacktrace ->
            Parent ! {error, self(), {Error, Reason, Stacktrace}}
    end.

write_loop(_, _, Current, Target) when Current >= Target ->
    ok;
write_loop(Db, WorkerId, Current, Target) ->
    % Mix of operations to stress the system
    Op = Current rem 10,
    Key = <<WorkerId:32, Current:64>>,
    
    case Op of
        N when N < 6 ->  % 60% regular puts
            Value = crypto:strong_rand_bytes(1000), % 1KB values
            elmdb:put(Db, Key, Value);
        N when N < 8 ->  % 20% async puts
            Value = crypto:strong_rand_bytes(1000),
            elmdb:async_put(Db, Key, Value);
        8 ->  % 10% reads
            elmdb:get(Db, Key);
        9 ->  % 10% deletes
            elmdb:delete(Db, Key)
    end,
    
    % Every 10k ops, do a sync to force page touches
    case Current rem 10000 of
        0 -> catch elmdb:sync(Db);
        _ -> ok
    end,
    
    write_loop(Db, WorkerId, Current + 1, Target).

monitor_db_size(Env) ->
    monitor_loop(Env, 0, 0).

monitor_loop(Env, LastSize, Iteration) ->
    receive
        stop -> ok
    after 5000 ->  % Check every 5 seconds
        case elmdb:env_stat(Env) of
            {ok, Stats} ->
                Psize = maps:get(psize, Stats),
                TotalPages = maps:get(branch_pages, Stats) + 
                            maps:get(leaf_pages, Stats) + 
                            maps:get(overflow_pages, Stats),
                CurrentSizeBytes = Psize * TotalPages,
                CurrentSizeGB = CurrentSizeBytes / (1024*1024*1024),
                UsedPct = maps:get(used_percentage, Stats) * 100,
                
                if
                    Iteration rem 12 == 0 orelse CurrentSizeGB > LastSize + 0.1 ->
                        io:format("Progress: ~.2f GB used (~.1f%), ~p entries~n", 
                                 [CurrentSizeGB, UsedPct, maps:get(entries, Stats)]);
                    true ->
                        ok
                end,
                
                % Alert when approaching 5GB
                if
                    LastSize < 4.5 andalso CurrentSizeGB >= 4.5 ->
                        io:format("~n*** APPROACHING 5GB THRESHOLD ***~n~n");
                    LastSize < 5.0 andalso CurrentSizeGB >= 5.0 ->
                        io:format("~n*** CROSSED 5GB THRESHOLD ***~n~n");
                    true ->
                        ok
                end,
                
                monitor_loop(Env, CurrentSizeGB, Iteration + 1);
            _ ->
                monitor_loop(Env, LastSize, Iteration + 1)
        end
    end.

collect_results([], Results) ->
    Results;
collect_results(Workers, Results) ->
    receive
        {done, Pid, Ops} ->
            RemainingWorkers = lists:delete(Pid, Workers),
            collect_results(RemainingWorkers, [{done, Pid, Ops} | Results]);
        {error, Pid, Error} ->
            RemainingWorkers = lists:delete(Pid, Workers),
            collect_results(RemainingWorkers, [{error, Pid, Error} | Results])
    after 300000 ->  % 5 minute timeout
        io:format("~nTimeout waiting for workers: ~p~n", [Workers]),
        lists:foreach(fun(W) -> exit(W, timeout) end, Workers),
        Results
    end.