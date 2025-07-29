# MDB_FREELIST_SAVE Assertion Failure Fix

## Issue
Client reported: `Assertion 'pglast <= env->me_pglast' failed in mdb_freelist_save()`

This critical assertion failure occurs in LMDB's freelist management during transaction commit.

## Root Cause
The auto-resize feature was attempting to resize the database map while transactions were still in flight. This caused corruption in LMDB's freelist state because:

1. `mdb_env_set_mapsize()` was called while the worker thread was processing operations
2. The resize changed the environment state while a transaction was committing
3. The freelist save operation found inconsistent page numbers

## Immediate Fix
Disabled auto-resize feature to prevent database corruption:
```c
elmdb_env->auto_resize = 0;  /* DISABLED until safe implementation */
```

## Long-term Solution
To safely implement auto-resize, we need:

1. **Complete Operation Quiescence**
   - Stop accepting new operations
   - Wait for ALL in-flight operations to complete (not just transactions)
   - Ensure worker thread is idle

2. **Coordinated Resize**
   - All processes using the database must coordinate
   - Consider external resize coordinator
   - Handle MDB_MAP_RESIZED errors in all operations

3. **Alternative Approaches**
   - Monitor externally and restart with larger map size
   - Pre-allocate sufficient space to avoid resizing
   - Use separate process for resize coordination

## Lessons Learned
- LMDB map resizing is extremely sensitive to timing
- Cannot safely resize while ANY operations are in progress
- Freelist corruption is a critical failure that requires immediate fix