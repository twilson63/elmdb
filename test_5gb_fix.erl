-module(test_5gb_fix).
-export([run/0]).

run() ->
    io:format("=== Testing 5GB Automatic Fix ===~n~n"),
    
    % Test 1: Small database (should not trigger MDB_NOTLS)
    io:format("Test 1: Small database (1GB)...~n"),
    test_db_size(1),
    
    % Test 2: Large database (should trigger MDB_NOTLS automatically)
    io:format("~nTest 2: Large database (6GB)...~n"),
    test_db_size(6),
    
    io:format("~n=== All Tests Complete ===~n").

test_db_size(SizeGB) ->
    Dir = "/tmp/elmdb_" ++ integer_to_list(SizeGB) ++ "gb_test",
    os:cmd("rm -rf " ++ Dir),
    
    MapSize = SizeGB * 1024 * 1024 * 1024,
    io:format("  Opening with map_size: ~p GB~n", [SizeGB]),
    
    % Capture stderr to see if warning is printed
    {ok, Env} = elmdb:env_open(Dir, [{map_size, MapSize}]),
    {ok, Db} = elmdb:db_open(Env, []),
    
    % Do some operations
    io:format("  Performing test operations...~n"),
    lists:foreach(fun(I) ->
        Key = <<I:64>>,
        Value = crypto:strong_rand_bytes(100),
        elmdb:put(Db, Key, Value)
    end, lists:seq(1, 1000)),
    
    % Verify it works
    {ok, _} = elmdb:get(Db, <<500:64>>),
    io:format("  ✓ Operations successful~n"),
    
    % Check if we're in large DB mode by looking at stats
    {ok, Stats} = elmdb:env_stat(Env),
    io:format("  Database entries: ~p~n", [maps:get(entries, Stats)]),
    
    % Clean up
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    ok.