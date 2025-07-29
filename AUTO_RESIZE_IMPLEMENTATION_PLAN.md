# Auto-Resize Implementation Plan for elmdb

## Overview
Implement automatic map resizing when database usage reaches 75% of the current map_size.

## LMDB Constraints

1. **Map size can only be increased**: LMDB doesn't allow shrinking the map size
2. **No active transactions**: Map size can only be changed when there are no active write transactions
3. **Process coordination**: All processes using the environment need to be aware of resize
4. **MDB_MAP_RESIZED error**: Other processes will get this error and need to call `mdb_env_set_mapsize(env, 0)` to adopt the new size

## Implementation Strategy

### 1. Add Statistics Functions
First, we need to expose LMDB statistics to monitor usage:

```c
// In elmdb_nif.c
static ERL_NIF_TERM elmdb_env_stat(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    MDB_stat stat;
    MDB_envinfo info;
    
    mdb_env_stat(elmdb_env->env, &stat);
    mdb_env_info(elmdb_env->env, &info);
    
    // Return tuple with current usage info
    return enif_make_tuple(...);
}
```

### 2. Monitor Database Usage
Add periodic checking in the worker thread:

```c
// Check every N operations or on timer
if (should_check_size()) {
    MDB_stat stat;
    MDB_envinfo info;
    
    mdb_env_stat(env, &stat);
    mdb_env_info(env, &info);
    
    size_t used = stat.ms_psize * (info.me_last_pgno + 1);
    size_t total = info.me_mapsize;
    
    if (used > total * 0.75) {
        // Trigger resize
    }
}
```

### 3. Resize Logic

```c
static int auto_resize_map(ElmdbEnv *elmdb_env) {
    // 1. Wait for all active transactions to complete
    // 2. Calculate new size (e.g., double current size)
    // 3. Call mdb_env_set_mapsize()
    // 4. Notify Erlang process of resize
}
```

### 4. Configuration Options

Add options to `env_open/2`:
- `{auto_resize, boolean()}` - Enable/disable auto-resize (default: true)
- `{resize_threshold, float()}` - Threshold percentage (default: 0.75)
- `{resize_factor, float()}` - How much to increase (default: 2.0)
- `{max_map_size, integer()}` - Maximum allowed size

### 5. Handle MDB_MAP_RESIZED

When other processes get MDB_MAP_RESIZED:
1. Call `mdb_env_set_mapsize(env, 0)` to adopt new size
2. Retry the operation

## API Additions

### Erlang API
```erlang
% Get environment statistics
-spec env_stat(env()) -> {ok, #{
    map_size := non_neg_integer(),
    used_bytes := non_neg_integer(),
    used_percentage := float(),
    page_size := non_neg_integer(),
    depth := non_neg_integer(),
    branch_pages := non_neg_integer(),
    leaf_pages := non_neg_integer(),
    overflow_pages := non_neg_integer(),
    entries := non_neg_integer()
}} | elmdb_error().

% Manually resize
-spec env_set_mapsize(env(), non_neg_integer()) -> ok | elmdb_error().

% Configure auto-resize
-spec env_set_auto_resize(env(), boolean()) -> ok | elmdb_error().
```

## Safety Considerations

1. **Transaction coordination**: Must ensure no active write transactions during resize
2. **Size limits**: Respect system limits and configured maximum
3. **Notification**: All processes need to be notified of resize
4. **Retry logic**: Operations that fail due to resize should retry
5. **Configuration persistence**: Remember auto-resize settings

## Testing Strategy

1. **Fill test**: Gradually fill database and verify resize triggers at 75%
2. **Concurrent test**: Multiple processes writing during resize
3. **Limit test**: Verify max_map_size is respected
4. **Recovery test**: Verify processes recover from MDB_MAP_RESIZED
5. **Performance test**: Measure resize impact on operations

## Implementation Steps

1. ✓ Research LMDB resize constraints
2. Add env_stat NIF function
3. Add resize monitoring to worker thread
4. Implement resize coordination logic
5. Add configuration options
6. Handle MDB_MAP_RESIZED in all operations
7. Add Erlang API functions
8. Write comprehensive tests
9. Document feature and best practices