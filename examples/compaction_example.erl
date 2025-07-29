-module(compaction_example).

%% Example module showing practical LMDB compaction patterns
%% Demonstrates when and how to use compaction in production

-export([
    online_compaction/2,
    scheduled_compaction/3,
    compaction_with_metrics/2
]).

%% @doc Perform online compaction - compact to new location then swap
%% This pattern allows compaction without downtime
online_compaction(DbPath, TempPath) ->
    %% Step 1: Open the current database
    {ok, Env} = elmdb:env_open(DbPath, []),
    
    %% Step 2: Check current size
    InitialSize = get_db_size(DbPath),
    io:format("Current database size: ~.2f MB~n", [InitialSize / 1024 / 1024]),
    
    %% Step 3: Compact to temporary location
    CompactPath = TempPath ++ ".compact",
    io:format("Compacting to temporary location: ~s~n", [CompactPath]),
    
    StartTime = erlang:system_time(millisecond),
    ok = elmdb:env_copy_compact(Env, CompactPath),
    Duration = erlang:system_time(millisecond) - StartTime,
    
    %% Step 4: Check compacted size
    CompactSize = get_db_size(CompactPath),
    io:format("Compacted size: ~.2f MB (saved ~.1f%)~n", 
              [CompactSize / 1024 / 1024, 
               ((InitialSize - CompactSize) / InitialSize) * 100]),
    io:format("Compaction took ~p ms~n", [Duration]),
    
    %% Step 5: Close environment
    elmdb:env_close(Env),
    
    %% Step 6: Atomic swap (requires application coordination)
    %% In production, you would:
    %% 1. Stop new writes
    %% 2. Close all connections
    %% 3. Rename directories
    %% 4. Reopen connections
    
    BackupPath = DbPath ++ ".backup",
    file:rename(DbPath, BackupPath),
    file:rename(CompactPath, DbPath),
    
    io:format("Compaction complete. Old database backed up to: ~s~n", [BackupPath]),
    
    {ok, [{initial_size, InitialSize},
          {compact_size, CompactSize},
          {space_saved, InitialSize - CompactSize},
          {duration_ms, Duration}]}.

%% @doc Scheduled compaction with thresholds
%% Only compact if fragmentation exceeds threshold
scheduled_compaction(DbPath, TempPath, FragmentationThreshold) ->
    %% Open database in read-only mode for analysis
    {ok, Env} = elmdb:env_open(DbPath, [read_only]),
    {ok, Dbi} = elmdb:db_open(Env, <<>>, []),
    
    %% Estimate fragmentation (simplified - in practice use stats)
    DbSize = get_db_size(DbPath),
    RecordCount = estimate_record_count(Dbi),
    AvgRecordSize = 200, % Assume average record size
    ExpectedSize = RecordCount * AvgRecordSize * 1.5, % With some overhead
    FragmentationRatio = (DbSize - ExpectedSize) / DbSize,
    
    io:format("Database analysis:~n"),
    io:format("  Size: ~.2f MB~n", [DbSize / 1024 / 1024]),
    io:format("  Estimated records: ~p~n", [RecordCount]),
    io:format("  Fragmentation: ~.1f%~n", [FragmentationRatio * 100]),
    
    Result = if
        FragmentationRatio > FragmentationThreshold ->
            io:format("Fragmentation exceeds threshold (~.1f%), starting compaction~n",
                      [FragmentationThreshold * 100]),
            elmdb:env_close(Env),
            online_compaction(DbPath, TempPath);
        true ->
            io:format("Fragmentation below threshold, skipping compaction~n"),
            elmdb:env_close(Env),
            {ok, skipped}
    end,
    
    Result.

%% @doc Compaction with detailed metrics and reader cleanup
compaction_with_metrics(DbPath, CompactPath) ->
    %% Clean up any stale readers first
    {ok, Env} = elmdb:env_open(DbPath, []),
    
    io:format("Checking for stale readers...~n"),
    {ok, StaleCount} = elmdb:reader_check(Env),
    io:format("Cleared ~p stale reader slots~n", [StaleCount]),
    
    %% Collect pre-compaction metrics
    PreStats = collect_stats(DbPath),
    
    %% Perform compaction
    io:format("Starting compaction...~n"),
    StartTime = erlang:system_time(millisecond),
    ok = elmdb:env_copy_compact(Env, CompactPath),
    Duration = erlang:system_time(millisecond) - StartTime,
    
    %% Collect post-compaction metrics
    PostStats = collect_stats(CompactPath),
    
    elmdb:env_close(Env),
    
    %% Generate report
    io:format("~nCompaction Report:~n"),
    io:format("==================~n"),
    io:format("Duration: ~p ms~n", [Duration]),
    io:format("Original size: ~.2f MB~n", [PreStats#stats.size / 1024 / 1024]),
    io:format("Compacted size: ~.2f MB~n", [PostStats#stats.size / 1024 / 1024]),
    io:format("Space saved: ~.2f MB (~.1f%)~n", 
              [(PreStats#stats.size - PostStats#stats.size) / 1024 / 1024,
               ((PreStats#stats.size - PostStats#stats.size) / PreStats#stats.size) * 100]),
    io:format("Pages: ~p -> ~p~n", [PreStats#stats.pages, PostStats#stats.pages]),
    io:format("Throughput: ~.2f MB/s~n", 
              [PreStats#stats.size / 1024 / 1024 / (Duration / 1000)]),
    
    {ok, #{
        duration_ms => Duration,
        original_size => PreStats#stats.size,
        compacted_size => PostStats#stats.size,
        space_saved => PreStats#stats.size - PostStats#stats.size,
        stale_readers_cleared => StaleCount
    }}.

%% Helper functions

-record(stats, {
    size :: integer(),
    pages :: integer()
}).

get_db_size(Path) ->
    DataFile = filename:join(Path, "data.mdb"),
    case file:read_file_info(DataFile) of
        {ok, #file_info{size = Size}} -> Size;
        _ -> 0
    end.

collect_stats(Path) ->
    Size = get_db_size(Path),
    Pages = Size div 4096, % Assuming 4KB pages
    #stats{size = Size, pages = Pages}.

estimate_record_count(Dbi) ->
    %% Simple estimation - count first 1000 records and extrapolate
    %% In production, use proper statistics
    Count = count_records(Dbi, 1000),
    Count * 10. % Rough estimate

count_records(Dbi, Limit) ->
    count_records(Dbi, 0, Limit).

count_records(_Dbi, Count, 0) -> Count;
count_records(Dbi, Count, Remaining) ->
    %% This is a simplified example
    %% In practice, use cursors for efficient counting
    Count.