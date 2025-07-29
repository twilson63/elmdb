-module(test_auto_resize).
-export([run/0]).

run() ->
    io:format("=== Testing Auto-Resize Feature ===~n~n"),
    
    Dir = "/tmp/elmdb_auto_resize_test",
    os:cmd("rm -rf " ++ Dir),
    
    % Start with a small map size to trigger resize quickly
    InitialMapSize = 10 * 1024 * 1024,  % 10MB
    
    % Open environment with auto-resize enabled
    Opts = [
        {map_size, InitialMapSize},
        {auto_resize, true},
        {resize_threshold, 0.75},
        {resize_factor, 2.0},
        {max_map_size, 100 * 1024 * 1024}  % 100MB max
    ],
    
    io:format("Opening environment with:~n"),
    io:format("  Initial map size: ~s~n", [format_bytes(InitialMapSize)]),
    io:format("  Auto-resize: enabled~n"),
    io:format("  Resize threshold: 75%~n"),
    io:format("  Resize factor: 2x~n"),
    io:format("  Max map size: 100MB~n~n"),
    
    {ok, Env} = elmdb:env_open(Dir, Opts),
    {ok, Dbi} = elmdb:db_open(Env, []),
    
    % Monitor function
    MonitorFun = fun() ->
        {ok, Stats} = elmdb:env_stat(Env),
        MapSize = maps:get(map_size, Stats),
        UsedBytes = maps:get(used_bytes, Stats),
        UsedPct = maps:get(used_percentage, Stats),
        io:format("Map: ~s, Used: ~s (~.1f%)~n", 
                  [format_bytes(MapSize), format_bytes(UsedBytes), UsedPct]),
        {MapSize, UsedPct}
    end,
    
    % Initial stats
    io:format("Initial state:~n"),
    {InitSize, _} = MonitorFun(),
    
    % Fill the database to trigger resize
    io:format("~nFilling database to trigger resize...~n"),
    
    ValueSize = 1024,  % 1KB values
    Value = binary:copy(<<0>>, ValueSize),
    
    FillLoop = fun Loop(N, LastMapSize) ->
        Key = <<N:64>>,
        elmdb:put(Dbi, Key, Value),
        
        % Check stats every 100 operations
        if N rem 100 == 0 ->
            {CurrentMapSize, UsedPct} = MonitorFun(),
            
            % Check if resize happened
            if CurrentMapSize > LastMapSize ->
                io:format("~n*** RESIZE DETECTED! ***~n"),
                io:format("Map size increased from ~s to ~s~n", 
                         [format_bytes(LastMapSize), format_bytes(CurrentMapSize)]),
                io:format("~n")
            ; true ->
                ok
            end,
            
            % Continue if we haven't reached the max and usage is below 90%
            if UsedPct < 90.0, CurrentMapSize < 100 * 1024 * 1024 ->
                Loop(N + 1, CurrentMapSize)
            ; true ->
                {N, CurrentMapSize, UsedPct}
            end
        ; true ->
            Loop(N + 1, LastMapSize)
        end
    end,
    
    {NumEntries, FinalMapSize, FinalUsedPct} = FillLoop(1, InitSize),
    
    io:format("~n=== Test Results ===~n"),
    io:format("Total entries written: ~p~n", [NumEntries]),
    io:format("Initial map size: ~s~n", [format_bytes(InitSize)]),
    io:format("Final map size: ~s~n", [format_bytes(FinalMapSize)]),
    io:format("Final usage: ~.1f%~n", [FinalUsedPct]),
    
    % Verify resize happened
    if FinalMapSize > InitSize ->
        io:format("~n✓ Auto-resize SUCCESSFUL!~n"),
        io:format("  Map size increased ~.1fx~n", [FinalMapSize / InitSize])
    ; true ->
        io:format("~n✗ Auto-resize did NOT occur~n")
    end,
    
    % Test concurrent operations during potential resize
    io:format("~nTesting concurrent operations...~n"),
    
    NumWorkers = 10,
    OpsPerWorker = 100,
    
    Parent = self(),
    Workers = [spawn(fun() ->
        lists:foreach(fun(I) ->
            K = <<(W * 1000000 + I):64>>,
            V = <<I:64>>,
            case elmdb:async_put(Dbi, K, V) of
                ok -> ok;
                {error, _} = Err -> Parent ! {error, self(), Err}
            end
        end, lists:seq(1, OpsPerWorker)),
        Parent ! {done, self()}
    end) || W <- lists:seq(1, NumWorkers)],
    
    % Wait for all workers
    lists:foreach(fun(Worker) ->
        receive
            {done, Worker} -> ok;
            {error, Worker, Err} -> 
                io:format("Worker ~p error: ~p~n", [Worker, Err])
        after 5000 ->
            io:format("Worker ~p timeout~n", [Worker])
        end
    end, Workers),
    
    io:format("All concurrent operations completed~n"),
    
    % Final stats
    io:format("~nFinal statistics:~n"),
    MonitorFun(),
    
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    io:format("~n=== Test Complete ===~n").

format_bytes(Bytes) when Bytes < 1024 ->
    io_lib:format("~B bytes", [Bytes]);
format_bytes(Bytes) when Bytes < 1024 * 1024 ->
    io_lib:format("~.2f KB", [Bytes / 1024]);
format_bytes(Bytes) when Bytes < 1024 * 1024 * 1024 ->
    io_lib:format("~.2f MB", [Bytes / (1024 * 1024)]);
format_bytes(Bytes) ->
    io_lib:format("~.2f GB", [Bytes / (1024 * 1024 * 1024)]).