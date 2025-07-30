# elmdb 5GB Database Fix - User Guide

## Issue
When elmdb databases exceed 5GB in size, you may encounter:
```
Assertion 'mp->mp_pgno != pgno' failed in mdb_page_touch()
```

## Automatic Fix (Latest Version)
The latest version of elmdb automatically detects when map_size >= 5GB and enables MDB_NOTLS to prevent this issue. You'll see:
```
elmdb: Large database mode activated (map_size >= 5GB). Using MDB_NOTLS to prevent page collisions.
```

## Manual Workarounds (If Needed)

### Option 1: Explicit MDB_NOTLS (Recommended)
```erlang
{ok, Env} = elmdb:env_open("/path/to/db", [
    {map_size, 10 * 1024 * 1024 * 1024},  % 10GB
    notls  % Add this flag
]).
```

### Option 2: Use MDB_WRITEMAP
```erlang
{ok, Env} = elmdb:env_open("/path/to/db", [
    {map_size, 10 * 1024 * 1024 * 1024},  % 10GB
    write_map  % Memory-mapped writes
]).
```

### Option 3: Limit Concurrency
Use a single writer process:
```erlang
% In your supervisor
{writer_process, {db_writer, start_link, []}, permanent, 5000, worker, [db_writer]}

% All writes go through this process
db_writer:write(Key, Value)
```

## When This Happens
- Database size approaches or exceeds 5GB
- High concurrency (multiple schedulers/processes)
- Random key access patterns

## Performance Impact
- MDB_NOTLS: Minimal impact, required for stability at scale
- MDB_WRITEMAP: Can improve write performance, requires OS sparse file support
- Single writer: Reduces concurrency but guarantees safety

## Best Practices
1. **Pre-allocate map_size** larger than expected data size
2. **Monitor database size** with `elmdb:env_stat/1`
3. **Test with production-sized data** before deployment
4. **Use sequential keys** when possible for better space efficiency

## Checking Your Database Size
```erlang
{ok, Stats} = elmdb:env_stat(Env),
SizeGB = (maps:get(psize, Stats) * 
          (maps:get(branch_pages, Stats) + 
           maps:get(leaf_pages, Stats) + 
           maps:get(overflow_pages, Stats))) / (1024*1024*1024),
io:format("Database size: ~.2f GB~n", [SizeGB]).
```

## Summary
- Databases < 5GB: Work normally
- Databases >= 5GB: Automatic MDB_NOTLS activation
- No manual intervention needed with latest version
- Performance remains excellent at any scale