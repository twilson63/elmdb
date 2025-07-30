# MDB_PAGE_DIRTY Assertion Fix

## Issue
Client reported: `Assertion 'rc == 0' failed in mdb_page_dirty()` when using:
- `no_sync` flag
- `no_mem_init` flag  
- After removing `MDB_NOTLS`

## Root Cause
The assertion failure occurs because the dirty page list overflows its maximum size limit:
- LMDB's dirty list has a hard limit of 131,071 entries (2^17 - 1)
- Without `MDB_NOTLS`, thread-local storage makes dirty page tracking more strict
- The combination of `no_sync` + `no_mem_init` causes rapid dirty page accumulation
- High concurrency quickly exceeds the dirty list limit

## Understanding the Flags

### MDB_NOSYNC
- Disables synchronous disk flushes
- Transactions accumulate in memory
- More pages stay dirty longer

### MDB_NOMEMINIT  
- Skips zeroing allocated memory
- Faster writes but more dirty pages

### MDB_NOTLS (removed)
- Without it: Strict thread-local reader tracking
- With it: More relaxed dirty page management

## The Fix
When both `no_sync` and `no_mem_init` are used together, we now:
1. **Re-enable MDB_NOTLS** for this specific combination
2. This prevents the dirty list overflow while maintaining performance

```c
if ((env_opts->flags & MDB_NOSYNC) && (env_opts->flags & MDB_NOMEMINIT)) {
    env_opts->flags |= MDB_NOTLS;
}
```

## Alternative Solution
Use `MDB_WRITEMAP` instead:
- Bypasses the dirty list entirely
- Uses direct memory-mapped writes
- Requires OS support for sparse files

## Trade-offs
- **With fix**: Slightly less thread safety but prevents crashes
- **Without fix**: Better thread isolation but dirty list overflow
- The fix only applies when both flags are used together

## Recommendations
1. Monitor dirty page accumulation with high write loads
2. Consider using `MDB_WRITEMAP` for write-heavy workloads
3. Ensure adequate map_size to reduce page recycling pressure