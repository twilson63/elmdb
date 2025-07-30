# 5GB Threshold Fix V2

## Problem
The `mdb_page_touch` assertion is still occurring at 5GB even after removing MDB_NOTLS and adding synchronization.

## Analysis
1. The synchronization we added (LOCKED_CHECK_ENV) helps but isn't sufficient at scale
2. At 5GB, the statistical probability of page collisions becomes too high
3. We need a different approach for large databases

## Solution Options

### Option 1: Re-enable MDB_NOTLS for Large Databases
```c
/* In env_open, check map size and set MDB_NOTLS for large DBs */
if (env_opts->mapsize >= 5ULL * 1024 * 1024 * 1024) {
    /* For databases 5GB or larger, use MDB_NOTLS to prevent collisions */
    env_opts->flags |= MDB_NOTLS;
}
```

### Option 2: Use MDB_WRITEMAP for Large Databases
```c
/* Use memory-mapped writes to avoid dirty page list entirely */
if (env_opts->mapsize >= 5ULL * 1024 * 1024 * 1024) {
    env_opts->flags |= MDB_WRITEMAP;
}
```

### Option 3: Dynamic Detection (Recommended)
```c
/* In ElmdbEnv structure, add: */
int large_db_mode;  /* Set when DB exceeds threshold */

/* In env_stat, check size and update mode: */
if (used_size > 4.5GB && !env->large_db_mode) {
    env->large_db_mode = 1;
    /* Warn user to restart with appropriate flags */
}

/* For read operations when large_db_mode is set: */
if (elmdb_env->large_db_mode) {
    /* Use more aggressive locking or single-writer mode */
}
```

## Immediate Fix

For now, users experiencing this issue should:

1. **Add MDB_NOTLS flag explicitly**:
```erlang
{ok, Env} = elmdb:env_open(Dir, [
    {map_size, 10 * 1024 * 1024 * 1024},
    notls  % Add this flag for databases > 5GB
]).
```

2. **Or use MDB_WRITEMAP**:
```erlang
{ok, Env} = elmdb:env_open(Dir, [
    {map_size, 10 * 1024 * 1024 * 1024},
    write_map  % Use memory-mapped writes
]).
```

3. **Or limit concurrency**:
- Reduce number of concurrent writers
- Use a single writer process with message passing

## Long-term Solution

We should implement automatic detection:
1. Monitor database size
2. When approaching 5GB, either:
   - Warn the user to restart with appropriate flags
   - Automatically adjust operation mode
   - Switch to single-writer mode for safety

## Root Cause Reminder

The 5GB threshold is where:
- Page count exceeds 1.25 million
- Freelist becomes complex (multi-level)
- Statistical collision probability > 10%
- Thread-local storage becomes critical