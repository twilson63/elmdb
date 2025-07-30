# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Compile the project (downloads LMDB if needed)
rebar3 compile

# Run tests
rebar3 eunit              # Unit tests
rebar3 ct                  # Common Test suite

# Run specific test
rebar3 eunit --module=elmdb_tests

# Clean build artifacts
rebar3 clean

# Interactive shell
rebar3 shell
```

## Architecture Overview

elmdb is an Erlang NIF wrapper for LMDB that solves transaction thread-safety by:

1. **Single Background Thread per Environment**: All write operations are serialized to a dedicated thread per LMDB environment, ensuring transaction operations execute on the same thread.

2. **Async Operation Queue**: Write operations (`async_put`, `async_get`, `async_delete`) are pushed to a FIFO queue and processed by the background thread. Results are sent back as Erlang messages.

3. **Transaction Isolation**: Recent fixes ensure async operations never reuse transactions, preventing assertion failures during concurrent access.

4. **Automatic Map Resizing**: Database automatically grows when reaching 75% capacity, preventing MDB_MAP_FULL errors.

## Critical Implementation Details

### C NIF Architecture (`c_src/elmdb_nif.c`)

- **Write Throttling**: Limited to 200 concurrent writers via `MAX_CONCURRENT_WRITES`
- **Retry Logic**: Handles `MDB_CORRUPTED` errors with up to 3 retries and progressive backoff (1-3ms)
- **Resource Management**: All LMDB objects are NIF resources with proper reference counting
- **Thread Safety**: One worker thread per environment handles all write transactions
- **Auto-Resize**: DISABLED - causes freelist corruption under high concurrency

### Recent Fixes Applied

1. **mdb_page_touch assertion fix**: Async operations now use isolated transactions
2. **mdb_page_search_root fix**: Added retry logic for transient MDB_CORRUPTED errors
3. **High concurrency support**: Non-blocking write throttling prevents deadlocks
4. **mdb_freelist_save fix**: Disabled auto-resize to prevent freelist corruption

### Auto-Resize Feature - CURRENTLY DISABLED

**WARNING**: The auto-resize feature is currently DISABLED due to `mdb_freelist_save` assertion failures that occur when resizing while transactions are in-flight.

The auto-resize feature would automatically increase the database map size when it reaches 75% capacity, but it causes database corruption under high concurrency:

```erlang
% DO NOT USE - Will be ignored even if specified
{ok, Env} = elmdb:env_open(Dir, [
    {map_size, 10485760},        % 10MB initial size
    {auto_resize, false},        % ALWAYS DISABLED (ignored if true)
    {resize_threshold, 0.75},    % Ignored
    {resize_factor, 2.0},        % Ignored
    {max_map_size, 1073741824}   % Ignored
]).
```

**Issue**: Causes `mdb.c:3184: Assertion 'pglast <= env->me_pglast' failed in mdb_freelist_save()` under high concurrency (e.g., 51k messages in hyperbeam).

**Workaround**: Set a larger initial `map_size` to avoid needing resize:
```erlang
{ok, Env} = elmdb:env_open(Dir, [{map_size, 10737418240}]).  % 10GB initial size
```

### Performance Baselines

- Single writer: ~50,000 ops/sec
- 100 concurrent: ~40,000 ops/sec
- 10,000 concurrent: ~15,000-16,000 ops/sec

## Known Issues and Solutions

### Large Database Support (>5GB) - FIXED
- **Previous Issue**: Assertion failures when database reached ~5GB
- **Root Cause**: MDB_NOTLS flag caused thread synchronization issues at scale
- **Solution**: Removed MDB_NOTLS flag and added proper synchronization
- **Details**: See `5GB_THRESHOLD_EXPLANATION.md` for complete analysis
- Still recommended: Set virtual memory ulimit to unlimited: `ulimit -v unlimited`

### System Configuration
```bash
# Check/set ulimits for LMDB
./check_ulimits.sh

# Recommended settings
ulimit -v unlimited  # Virtual memory
ulimit -n 65536      # File descriptors
```

## Testing Performance

```bash
# Run performance baseline test
erlc test_performance_baseline.erl
erl -pa ebin -noshell -s test_performance_baseline run -s init stop
```

## Key Files for Modifications

- `src/elmdb.erl` - Erlang API (rarely needs changes)
- `c_src/elmdb_nif.c` - All performance/stability fixes go here
- `c_src/Makefile` - Build configuration for LMDB integration

## Error Handling Patterns

Async operations return:
- `ok` - Success
- `not_found` - Key doesn't exist
- `exists` - Key already exists (put_new)
- `{error, Reason}` - Various errors including throttling timeout

## Debug Tips

1. Check for MDB_CORRUPTED retry events in logs
2. Monitor `g_active_writes` counter for throttling
3. Verify transaction cleanup in error paths
4. Use `DPRINTF` macro in C code for debugging (requires recompile with DEBUG flag)

## NIF Best Practices Compliance

### Thread Safety ✓
- **Proper synchronization**: All shared state protected by mutexes (`enif_mutex_lock/unlock`)
- **Dedicated worker thread**: One thread per environment handles all write transactions
- **No static variables**: All state stored in resource objects with proper locking

### Resource Management ✓
- **Resource types with destructors**: All LMDB objects have proper cleanup in `*_dtor` functions
- **Reference counting**: Uses `enif_keep_resource` and `enif_release_resource` correctly
- **Cleanup on error paths**: All error paths properly release resources

### Concurrency Patterns ✓
- **Async operations**: Long-running operations delegated to worker thread
- **Non-blocking**: Returns quickly to avoid scheduler monopolization
- **Condition variables**: Uses `enif_cond_wait/signal` for thread coordination

### Safety Considerations
- **Crash protection**: All NIF functions validate arguments with `BADARG`
- **Environment lifecycle**: Proper shutdown sequence with thread joins
- **Memory management**: No memory leaks, all allocations have matching frees

### Areas Following Best Practices
1. ✓ Resource destructors clean up properly even if app crashes
2. ✓ Thread-safe initialization with `enif_priv_data`
3. ✓ Mutexes released in all code paths (including errors)
4. ✓ Worker thread per environment (avoids scheduler blocking)
5. ✓ Proper use of `enif_alloc_env` for message passing

### Potential Improvements
1. Consider dirty NIFs for CPU-intensive operations (currently uses worker thread)
2. Add `enif_consume_timeslice` for operations that might take time
3. Consider using `enif_schedule_nif` for better scheduler cooperation