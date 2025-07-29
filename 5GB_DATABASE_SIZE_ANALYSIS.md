# 5GB Database Size Error Analysis

## The Problem

When the database size exceeds 5GB, you're likely hitting one of these LMDB errors:
- `MDB_MAP_FULL` - Environment mapsize limit reached
- `MDB_MAP_RESIZED` - Database contents grew beyond environment mapsize

## Root Cause

Looking at the code:

1. **Default map_size**: The default in elmdb is 1GB (1073741824 bytes):
```c
// elmdb_nif.c line 695
uint64_t _mapsize = 1073741824;  // 1GB default
```

2. **When you don't specify map_size**: LMDB uses this 1GB default or falls back to its own tiny default of 1MB.

3. **The 5GB threshold**: This suggests you might be using a 5GB map_size, but the actual data + overhead exceeds it.

## Why Errors Occur at 5GB

1. **LMDB Overhead**: LMDB needs extra space beyond your data:
   - B-tree structure overhead (~10-20%)
   - Free pages tracking
   - Metadata pages
   - Page alignment waste

2. **Map Size is a Hard Limit**: Once the database file reaches the map_size, LMDB returns `MDB_MAP_FULL` and refuses new writes.

3. **Cannot Resize While Open**: You cannot increase map_size while the environment is open. You must:
   - Close all handles
   - Reopen with larger map_size

## Common Scenarios

### Scenario 1: Using 5GB map_size
```erlang
{ok, Env} = elmdb:env_open(Dir, [{map_size, 5368709120}])  % 5GB
```
With overhead, you'll hit the limit around 4.5GB of actual data.

### Scenario 2: Platform Limitations
- 32-bit systems: Cannot handle map_size > 2-3GB
- Some VMs/containers: Memory limits prevent large mappings
- Some filesystems: Don't support sparse files well

## Solutions

### 1. Set Larger map_size Initially
```erlang
% For 5GB of data, use at least 6-7GB map_size
{ok, Env} = elmdb:env_open(Dir, [{map_size, 7516192768}])  % 7GB
```

### 2. Monitor Database Size
```erlang
% Get current usage
{ok, Stat} = elmdb:env_stat(Env),
% Check if approaching limit
```

### 3. Handle MDB_MAP_FULL Gracefully
```erlang
case elmdb:put(Dbi, Key, Val) of
    ok -> ok;
    {error, map_full} ->
        % Need to close and reopen with larger map_size
        handle_resize();
    Error -> Error
end
```

### 4. Pre-calculate Required Size
```erlang
% Estimate: (num_records * avg_record_size * 1.2) for 20% overhead
RequiredSize = round(NumRecords * AvgSize * 1.2),
MapSize = max(RequiredSize, 10737418240)  % At least 10GB
```

## Best Practices

1. **Always specify map_size** - Don't rely on defaults
2. **Overestimate** - Use 2-3x expected data size
3. **Monitor usage** - Track database growth
4. **Plan for growth** - LMDB cannot auto-resize
5. **Use large initial size** - Unused map_size doesn't consume disk space (sparse files)

## Platform-Specific Considerations

- **Linux**: Supports large sparse files well
- **macOS**: May have issues with very large map_size (>100GB)
- **Windows**: Different virtual memory handling
- **32-bit**: Hard limit around 2-3GB