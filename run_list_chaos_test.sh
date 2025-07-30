#!/bin/bash

echo "=== Running ELMDB List Operations Chaos Test ==="
echo ""

# Compile if needed
rebar3 compile

# Run the list chaos test
erl -pa _build/default/lib/elmdb/ebin -noshell -eval "elmdb_list_chaos_test:run(), init:stop()."

echo ""
echo "To run the full 50M benchmark with list operations:"
echo "  ./run_50m_benchmark.escript"