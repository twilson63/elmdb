-module(test_no_sync_no_mem_init).
-export([run/0]).

run() ->
    io:format("=== Testing no_sync + no_mem_init Flag Combination ===~n~n"),
    
    Dir = "/tmp/elmdb_flag_test",
    os:cmd("rm -rf " ++ Dir),
    
    % Test with the problematic flag combination
    io:format("Opening environment with no_sync + no_mem_init...~n"),
    {ok, Env} = elmdb:env_open(Dir, [
        {map_size, 100 * 1024 * 1024},
        no_sync,      % Client's flag
        no_mem_init   % Client's flag
    ]),
    {ok, Dbi} = elmdb:db_open(Env, []),
    
    % High-speed writes to trigger dirty page accumulation
    io:format("Performing rapid writes to test dirty page handling...~n"),
    
    NumWorkers = 50,
    OpsPerWorker = 2000,
    
    Parent = self(),
    Workers = lists:map(fun(W) ->
        spawn(fun() ->
            try
                lists:foreach(fun(I) ->
                    K = <<(W * 10000 + I):64>>,
                    V = binary:copy(<<I:8>>, 1000), % 1KB values
                    case I rem 3 of
                        0 -> elmdb:put(Dbi, K, V);
                        1 -> elmdb:async_put(Dbi, K, V);
                        2 -> 
                            case elmdb:get(Dbi, K) of
                                {ok, _} -> elmdb:delete(Dbi, K);
                                not_found -> ok
                            end
                    end
                end, lists:seq(1, OpsPerWorker)),
                Parent ! {done, self()}
            catch
                Error:Reason ->
                    Parent ! {error, self(), {Error, Reason}}
            end
        end)
    end, lists:seq(1, NumWorkers)),
    
    % Wait for all workers
    Results = lists:map(fun(Worker) ->
        receive
            {done, Worker} -> ok;
            {error, Worker, Error} -> {error, Error}
        after 10000 ->
            {error, {timeout, Worker}}
        end
    end, Workers),
    
    % Check results
    Errors = [E || {error, E} <- Results],
    case Errors of
        [] ->
            io:format("~n✓ SUCCESS: All ~p operations completed without mdb_page_dirty assertion!~n", 
                      [NumWorkers * OpsPerWorker]);
        _ ->
            io:format("~n✗ FAILED with errors: ~p~n", [Errors])
    end,
    
    % Check stats
    {ok, Stats} = elmdb:env_stat(Env),
    io:format("~nDatabase stats:~n"),
    io:format("  Entries: ~p~n", [maps:get(entries, Stats)]),
    io:format("  Used: ~.1f%~n", [maps:get(used_percentage, Stats)]),
    
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    io:format("~n=== Test Complete ===~n").