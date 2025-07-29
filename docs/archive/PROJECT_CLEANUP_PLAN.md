# Project Cleanup Plan

## Files to KEEP (Essential for continued development)

### Core Project Files
- `src/elmdb.erl` - Main Erlang module
- `c_src/elmdb_nif.c` - Core NIF implementation with all fixes
- `c_src/lmdb/` - LMDB source (required for compilation)
- `rebar.config` - Build configuration
- `rebar.lock` - Dependency lock file
- `.gitignore` - Git ignore rules
- `README.md` - Project documentation
- `LICENSE` - License file

### Important Documentation (for auditor/tester)
- `MDB_PAGE_SEARCH_ROOT_FIX_SUMMARY.md` - Latest fix documentation
- `PERFORMANCE_AUDIT_REPORT.md` - Performance baseline
- `ULIMIT_RECOMMENDATIONS.md` - System configuration guide
- `5GB_DATABASE_SIZE_ANALYSIS.md` - Known issue documentation

### Test Files to Keep (for tester)
- `test/elmdb_SUITE.erl` - Main test suite
- `examples/simple.erl` - Basic usage example
- `test_performance_comparison.erl` - Performance benchmark
- `test_page_search_fix.erl` - Regression test for latest fix

### Security Tools (for auditor)
- `.claude/agents/security-performance-auditor.md` - Security audit agent
- `.claude/agents/c-erlang-integration-tester.md` - Integration test agent

## Files to REMOVE

### Temporary Test Files
- All `test_*.erl` files except the ones listed above
- All `benchmark_*.erl` files
- All `.beam` files (compiled bytecode)
- All `erl_crash.dump` files

### Build Artifacts
- `_build/` directory (if exists)
- `priv/elmdb.so` (will be rebuilt)
- All `.o` files in c_src/

### Test Databases
- All directories ending with `_test/`, `_db/`, etc.
- `data.mdb` and `lock.mdb` files

### Development/Debug Files
- All `.patch` files (already applied)
- All `*_ANALYSIS.md` files except key ones
- All `*_PLAN.md` files
- All `TEST-*.xml` files
- All `.dSYM/` directories (debug symbols)

### Redundant C Source Files
- `c_src/elmdb_nif_*.c` (variants - we only need main file)
- `c_src/test_*.c` files
- `c_src/elmdb_security.*` (if not used)

### Log and Result Files
- All `*.log` files
- All `*.txt` result files
- All `*_results.*` files

## Cleanup Commands

```bash
# Remove compiled beam files
find . -name "*.beam" -type f -delete

# Remove test databases
find . -type d -name "*_test" -exec rm -rf {} + 2>/dev/null
find . -type d -name "*_db" -exec rm -rf {} + 2>/dev/null
find . -name "data.mdb" -o -name "lock.mdb" | xargs rm -f

# Remove crash dumps
find . -name "erl_crash.dump" -type f -delete

# Remove test executables and debug symbols
find c_src -name "test_*" -type f -perm +111 -delete
find . -name "*.dSYM" -type d -exec rm -rf {} + 2>/dev/null

# Remove patch files
find . -name "*.patch" -type f -delete

# Remove test XML files
find . -name "TEST-*.xml" -type f -delete

# Remove log files
find . -name "*.log" -type f -delete
find . -name "*.txt" -type f -delete
```