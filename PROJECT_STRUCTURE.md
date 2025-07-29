# elmdb Project Structure

## Core Files

### Source Code
- `src/elmdb.erl` - Main Erlang module with API
- `c_src/elmdb_nif.c` - NIF implementation with all fixes:
  - Non-blocking high concurrency write support
  - mdb_page_touch assertion fix
  - mdb_page_search_root retry logic for MDB_CORRUPTED
  - Write throttling (200 concurrent writers max)

### Build Configuration  
- `rebar.config` - Rebar3 build configuration
- `rebar.lock` - Dependency lock file
- `.gitignore` - Git ignore patterns

### Documentation
- `README.md` - Project overview and usage
- `LICENSE` - Apache 2.0 license
- `ULIMIT_RECOMMENDATIONS.md` - System configuration for large databases
- `5GB_DATABASE_SIZE_ANALYSIS.md` - Known issues with large map_size
- `MDB_PAGE_SEARCH_ROOT_FIX_SUMMARY.md` - Latest fix documentation
- `PERFORMANCE_AUDIT_REPORT.md` - Performance baselines and audit results

### Tests
- `test/elmdb_SUITE.erl` - Common Test suite
- `test/elmdb_tests.erl` - EUnit tests
- `test_performance_baseline.erl` - Performance benchmark
- `examples/simple.erl` - Basic usage example

### LMDB Source
- `c_src/lmdb/` - LMDB 0.9.31 source code

## For Developers

### Key Functions to Monitor
1. `elmdb_async_put_handler` - Async write with throttling
2. `elmdb_async_get_handler` - Async read with retry logic
3. `elmdb_async_delete_handler` - Async delete with retry
4. `elmdb_env_thread` - Worker thread with transaction isolation

### Performance Targets
- Single writer: ~50,000 ops/sec
- 100 concurrent: ~40,000 ops/sec  
- 10,000 concurrent: ~15,000-16,000 ops/sec

### Known Issues
1. Virtual memory ulimit must be unlimited for large map_size
2. Temporary MDB_CORRUPTED during page rebalancing (handled by retry)
3. Write throttling at 200 concurrent writers

## For Testers

### Running Tests
```bash
# Unit tests
rebar3 eunit

# Common Test
rebar3 ct

# Performance baseline
erlc test_performance_baseline.erl
erl -pa ebin -noshell -s test_performance_baseline run -s init stop
```

### Test Scenarios
1. High concurrency (10,000+ writers)
2. Large databases (50GB+ map_size)
3. Long-running operations
4. Error conditions (full disk, etc.)

## For Auditors

### Security Considerations
1. All input validation in NIF code
2. Resource limits enforced
3. No buffer overflows (bounded operations)
4. Proper mutex/lock ordering

### Performance Monitoring
1. Track retry frequency for MDB_CORRUPTED
2. Monitor write throttling events
3. Check memory usage patterns
4. Verify transaction cleanup

### Code Review Focus
1. `c_src/elmdb_nif.c` - All async handlers
2. Transaction lifecycle management
3. Error handling and cleanup paths
4. Resource allocation/deallocation