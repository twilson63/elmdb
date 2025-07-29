# mdb_page_search_root Assertion Fix

## Root Cause Analysis

The assertion `i < NUMKEYS(mp)` fails at line 5570 in mdb.c when `NUMKEYS(mp) == 0` because:

1. When `mdb_node_search()` returns NULL (line 5558):
   ```c
   if (node == NULL)
       i = NUMKEYS(mp) - 1;  // If NUMKEYS(mp) == 0, this underflows to UINT_MAX
   ```

2. The code then asserts `i < NUMKEYS(mp)` which fails when `i` is UINT_MAX and `NUMKEYS(mp)` is 0.

## How This Can Happen

Our recent changes to async transaction handling may have created a race condition where:

1. A branch page is being rebalanced and temporarily has 0 keys
2. Another thread/operation tries to search through this page
3. The assertion fails

## Connection to Our Changes

1. **mdb_page_touch fix**: Changed how transactions are handled
2. **Async isolation**: Transactions now start fresh for async operations
3. **Timing change**: This may have exposed a race condition where pages can be seen with 0 keys

## The Fix

We need to add a check before the assertion to handle empty pages gracefully:

```c
// In mdb_page_search_root, around line 5556:
node = mdb_node_search(mc, key, &exact);
if (node == NULL) {
    if (NUMKEYS(mp) == 0) {
        // Handle empty page - this shouldn't normally happen
        // but can occur during rebalancing
        return MDB_NOTFOUND;
    }
    i = NUMKEYS(mp) - 1;
} else {
    i = mc->mc_ki[mc->mc_top];
    if (!exact) {
        mdb_cassert(mc, i > 0);
        i--;
    }
}
```

## Alternative Approach

Since we can't modify LMDB source directly, we need to ensure our NIF code doesn't trigger this condition:

1. Add additional locking around operations that might see pages mid-rebalance
2. Ensure async operations don't interfere with page rebalancing
3. Add retry logic when encountering this error

## Recommended NIF-Level Fix

In `elmdb_nif.c`, we should:

1. Catch this specific assertion error
2. Add a small delay and retry the operation
3. This gives the rebalancing operation time to complete

```c
// In async operation handlers
int retry_count = 0;
while (retry_count < 3) {
    int rc = mdb_get(txn, dbi, &key, &val);
    if (rc == MDB_SUCCESS || rc != MDB_CORRUPTED) {
        break;
    }
    // Small delay to let rebalancing complete
    usleep(1000); // 1ms
    retry_count++;
}
```

## Verification

To verify this is the issue, we need a test that:
1. Creates a large dataset
2. Performs heavy concurrent deletions to trigger rebalancing
3. Has other threads searching during the rebalancing