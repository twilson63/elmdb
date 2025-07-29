-module(test_env_stat).
-export([run/0]).

run() ->
    io:format("=== Testing env_stat function ===~n~n"),
    
    Dir = "/tmp/elmdb_stat_test",
    os:cmd("rm -rf " ++ Dir),
    
    % Open environment with 100MB map size
    MapSize = 100 * 1024 * 1024,
    {ok, Env} = elmdb:env_open(Dir, [{map_size, MapSize}]),
    {ok, Dbi} = elmdb:db_open(Env, []),
    
    % Get initial stats
    io:format("Initial stats:~n"),
    {ok, Stats1} = elmdb:env_stat(Env),
    print_stats(Stats1),
    
    % Add some data
    io:format("~nAdding 10,000 entries...~n"),
    lists:foreach(fun(N) ->
        Key = <<N:64>>,
        Val = binary:copy(<<N:8>>, 1000), % 1KB values
        elmdb:put(Dbi, Key, Val)
    end, lists:seq(1, 10000)),
    
    % Get stats after adding data
    io:format("~nStats after adding data:~n"),
    {ok, Stats2} = elmdb:env_stat(Env),
    print_stats(Stats2),
    
    % Add more data to increase usage
    io:format("~nAdding 10,000 more entries...~n"),
    lists:foreach(fun(N) ->
        Key = <<(N + 10000):64>>,
        Val = binary:copy(<<N:8>>, 2000), % 2KB values
        elmdb:put(Dbi, Key, Val)
    end, lists:seq(1, 10000)),
    
    % Get final stats
    io:format("~nFinal stats:~n"),
    {ok, Stats3} = elmdb:env_stat(Env),
    print_stats(Stats3),
    
    % Check if we need resizing
    UsedPct = maps:get(used_percentage, Stats3),
    io:format("~n=== Resize Decision ===~n"),
    io:format("Used percentage: ~.2f%~n", [UsedPct]),
    if
        UsedPct > 75.0 ->
            io:format("WARNING: Database is ~.2f% full - resize recommended!~n", [UsedPct]);
        UsedPct > 50.0 ->
            io:format("Info: Database is ~.2f% full - monitor closely~n", [UsedPct]);
        true ->
            io:format("OK: Database usage is healthy (~.2f%)~n", [UsedPct])
    end,
    
    elmdb:env_close(Env),
    os:cmd("rm -rf " ++ Dir),
    
    io:format("~n=== Test Complete ===~n").

print_stats(Stats) ->
    MapSize = maps:get(map_size, Stats),
    UsedBytes = maps:get(used_bytes, Stats),
    UsedPct = maps:get(used_percentage, Stats),
    Entries = maps:get(entries, Stats),
    
    io:format("  Map size: ~s~n", [format_bytes(MapSize)]),
    io:format("  Used: ~s (~.2f%)~n", [format_bytes(UsedBytes), UsedPct]),
    io:format("  Entries: ~p~n", [Entries]),
    io:format("  Page size: ~p bytes~n", [maps:get(page_size, Stats)]),
    io:format("  B-tree depth: ~p~n", [maps:get(depth, Stats)]),
    io:format("  Leaf pages: ~p~n", [maps:get(leaf_pages, Stats)]),
    io:format("  Branch pages: ~p~n", [maps:get(branch_pages, Stats)]),
    io:format("  Overflow pages: ~p~n", [maps:get(overflow_pages, Stats)]).

format_bytes(Bytes) when Bytes < 1024 ->
    io_lib:format("~B bytes", [Bytes]);
format_bytes(Bytes) when Bytes < 1024 * 1024 ->
    io_lib:format("~.2f KB", [Bytes / 1024]);
format_bytes(Bytes) when Bytes < 1024 * 1024 * 1024 ->
    io_lib:format("~.2f MB", [Bytes / (1024 * 1024)]);
format_bytes(Bytes) ->
    io_lib:format("~.2f GB", [Bytes / (1024 * 1024 * 1024)]).