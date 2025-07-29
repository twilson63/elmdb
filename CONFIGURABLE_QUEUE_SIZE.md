# Configurable Queue Size Implementation

## Overview

Successfully implemented configurable queue size for elmdb async operations. Users can now specify the maximum queue size when opening an environment, allowing them to tune memory usage and backpressure behavior based on their specific needs.

## Usage

### Default Queue Size (10,000)
```erlang
{ok, Env} = elmdb:env_open("/path/to/db", []).
```

### Custom Queue Size
```erlang
% Small queue for low memory usage
{ok, Env} = elmdb:env_open("/path/to/db", [{queue_size, 100}]).

% Large queue for high throughput
{ok, Env} = elmdb:env_open("/path/to/db", [{queue_size, 50000}]).
```

## Implementation Details

### C Changes

1. **Added max_queue_size to ElmdbEnv structure**:
```c
typedef struct {
  // ... other fields ...
  int txn_queue_size;  /* Track queue size */
  int max_queue_size;  /* Configurable maximum queue size */
} ElmdbEnv;
```

2. **Updated env_open to accept queue_size parameter**:
```c
static int get_env_open_opts(ErlNifEnv *env, ERL_NIF_TERM opts, 
                            uint64_t *mapsize, unsigned int *maxdbs, 
                            unsigned int *flags, unsigned int *queue_size)
```

3. **Dynamic queue size checking**:
```c
if (elmdb_dbi->elmdb_env->txn_queue_size >= elmdb_dbi->elmdb_env->max_queue_size) {
    return enif_make_tuple2(env, 
                          enif_make_atom(env, "error"),
                          enif_make_atom(env, "queue_full"));
}
```

### Erlang API

The existing `env_open/2` function now accepts a `{queue_size, N}` option:

```erlang
-type env_open_option() :: 
    {map_size, non_neg_integer()} |
    {max_dbs, non_neg_integer()} |
    {queue_size, non_neg_integer()} |  % New option
    fixed_map | no_subdir | read_only | ...
```

## Performance Considerations

### Queue Size Guidelines

1. **Small Queue (100-1000)**:
   - Low memory footprint
   - Quick backpressure response
   - Good for memory-constrained systems
   - May limit throughput

2. **Default Queue (10,000)**:
   - Balanced performance and memory
   - Suitable for most applications
   - Good burst handling

3. **Large Queue (50,000+)**:
   - High throughput capability
   - Better burst absorption
   - Higher memory usage
   - Delayed backpressure

### Memory Usage

Each queue entry uses approximately:
- Queue node overhead: ~32 bytes
- Operation structure: ~64 bytes
- Data copies: varies by key/value size

Approximate memory usage:
- Queue size 1,000: ~100KB overhead
- Queue size 10,000: ~1MB overhead
- Queue size 50,000: ~5MB overhead

## Test Results

```
Test 1: Default queue size (10000)
  Queue full errors: 4675 (expected around 5000)
  Success: YES

Test 2: Small queue size (100)
  Queue full errors: 396 (expected around 400)
  Success: YES

Test 3: Large queue size (50000)
  Queue full errors: 8843 (expected around 10000)
  Success: YES (within acceptable variance)
```

## Best Practices

1. **Choose queue size based on**:
   - Expected concurrent writers
   - Available memory
   - Burst traffic patterns
   - Backpressure requirements

2. **Monitor queue usage**:
   - Track `{error, queue_full}` responses
   - Adjust queue size if needed
   - Consider multiple databases for extreme loads

3. **Example configurations**:
   ```erlang
   % Low latency, quick feedback
   [{queue_size, 500}]
   
   % High throughput batch processing
   [{queue_size, 50000}, {map_size, 10737418240}]
   
   % Memory constrained embedded system
   [{queue_size, 100}, {map_size, 104857600}]
   ```

## Benefits

1. **Flexibility**: Adapt to different workloads
2. **Memory Control**: Prevent unbounded growth
3. **Predictable Behavior**: Know your limits
4. **Performance Tuning**: Optimize for your use case

## Conclusion

The configurable queue size feature provides users with fine-grained control over async operation queuing behavior. This allows elmdb to be tuned for a wide range of use cases, from memory-constrained embedded systems to high-throughput server applications.