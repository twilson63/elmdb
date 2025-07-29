# mdb_page_touch Assertion Failure Analysis

## Root Cause Identified

The assertion `mp->mp_pgno != pgno` in `mdb_page_touch()` is triggered when LMDB tries to touch a page that already has the same page number. This indicates transaction state corruption.

## Specific Issue in elmdb

In the async worker thread (`elmdb_nif.c` around line 610):

```c
while(!STAILQ_EMPTY(&elmdb_env->txn_queue)) {
    POP(elmdb_env->txn_queue, q_txn);
    enif_mutex_unlock(elmdb_env->txn_lock);
    txn = q_txn->handler(txn, q_txn);  // <-- PROBLEM HERE
    enif_mutex_lock(elmdb_env->txn_lock);
    // ...
}
```

### The Problem

1. **Transaction Reuse**: The `txn` variable is passed between handlers
2. **Inconsistent Returns**: Some handlers return NULL, others return a valid txn
3. **Mixed Transaction Types**: Read-only operations (async_get) abort their transactions and return NULL, but the same txn pointer might be passed to write operations

### Specific Scenarios

1. **async_get_handler**: Always creates its own transaction, aborts it, returns NULL
2. **async_put_handler**: Creates its own transaction, commits/aborts it, returns NULL
3. **update handlers**: Expect to receive and reuse an existing transaction

## Why This Causes mdb_page_touch Assertion

When a transaction is aborted or committed, its internal state becomes invalid. If this transaction pointer is somehow reused or if there's memory corruption, LMDB's page management can see duplicate page numbers, triggering the assertion.

## Fix Strategy

1. **Never pass transactions between handlers** - Each async operation should be fully self-contained
2. **Clear transaction state** - Always ensure txn is NULL before calling a handler
3. **Add defensive checks** - Verify transaction state before operations

## Reproduction Pattern

The issue is most likely to occur when:
1. High concurrency with mixed read/write operations
2. Queue overflow/recovery scenarios
3. Rapid put/delete/put sequences on the same key
4. Large transactions that span multiple pages