# MDB_PAGE_TOUCH Final Fix

## Problem
Client continued to receive: `Assertion 'mp->mp_pgno != pgno' failed in mdb_page_touch()`

Despite our previous fixes for async operations, the error persisted.

## Root Cause Analysis
After deeper investigation, we found TWO critical issues:

### 1. MDB_NOTLS Flag Issue
- elmdb was using `MDB_NOTLS` flag by default
- This flag disables thread-local storage for reader slots
- With Erlang's multiple scheduler threads, this caused reader slot conflicts
- Without proper thread-local storage, concurrent operations could corrupt each other's state

### 2. Missing Synchronization on Read Operations
- Synchronous `get` operations used `UNLOCKED_CHECK_ENV` (no mutex)
- Multiple scheduler threads could execute reads simultaneously
- Combined with MDB_NOTLS, this created race conditions

## Solution Implemented

### 1. Removed MDB_NOTLS Flag
```c
// Before:
env_opts->flags = MDB_NOTLS;

// After:
env_opts->flags = 0;  /* Removed MDB_NOTLS to fix mdb_page_touch assertion */
```

### 2. Added Synchronization to Read Operations
```c
// Before:
UNLOCKED_CHECK_ENV(elmdb_dbi->elmdb_env);

// After:
LOCKED_CHECK_ENV(elmdb_dbi->elmdb_env);  /* Added synchronization to prevent race conditions */
```

## Test Results
Successfully ran stress test with:
- 100,000 mixed sync/async operations with 100 concurrent workers
- 20,000 concurrent read operations with 200 readers
- 5-second stress test with all operation types
- **NO assertion failures!**

## Key Takeaways
1. **MDB_NOTLS is dangerous** with multi-threaded environments like Erlang
2. **All LMDB operations need proper synchronization** when not using thread-local storage
3. The combination of Erlang scheduler threads + MDB_NOTLS + unsynchronized reads was lethal

This fix should finally resolve the mdb_page_touch assertion failures permanently.