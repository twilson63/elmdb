# Plan to Reproduce mdb_page_touch Assertion Failure

## Error Details
```
Assertion 'mp->mp_pgno != pgno' failed in mdb_page_touch()
```

This assertion indicates that LMDB is trying to touch a page that already has the same page number, suggesting corruption or improper transaction handling.

## Common Causes

1. **Transaction Reuse After Abort/Commit**
   - Using a transaction after it's been committed or aborted
   - Multiple threads using the same transaction

2. **Cursor Issues**
   - Using cursors after their transaction ends
   - Sharing cursors between threads

3. **Environment Corruption**
   - Writing to a read-only transaction
   - Memory corruption in the page cache

4. **Race Conditions**
   - Concurrent modifications without proper locking
   - Async operations interfering with each other

## Reproduction Strategy

### Test 1: Transaction Lifecycle Violations
```erlang
% Test double-commit, use-after-commit, use-after-abort
test_transaction_lifecycle_violations()
```

### Test 2: Concurrent Transaction Stress
```erlang
% Many readers + writers touching same pages
test_concurrent_page_access()
```

### Test 3: Async Queue Edge Cases
```erlang
% Test async operations that might reuse transactions
test_async_transaction_reuse()
```

### Test 4: Large Data Patterns
```erlang
% Test with data that spans multiple pages
test_multi_page_operations()
```

### Test 5: Cursor Misuse
```erlang
% Test cursor operations across transaction boundaries
test_cursor_transaction_violations()
```

## Implementation Plan

1. **Create Systematic Tests**
   - Each test targets a specific scenario
   - Use error injection if needed
   - Monitor for the exact assertion

2. **Add Debugging**
   - Log transaction IDs and states
   - Track page access patterns
   - Monitor async queue state

3. **Stress Testing**
   - High concurrency
   - Large transactions
   - Rapid open/close cycles

4. **Environment Analysis**
   - Check for corruption patterns
   - Verify memory safety
   - Analyze core dumps if available