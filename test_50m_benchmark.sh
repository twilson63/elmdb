#!/bin/bash

echo "=== Testing 50M Benchmark with Small Dataset ==="
echo ""
echo "This will run a quick test with 100k transactions to verify the benchmark works"
echo ""

# Run with small dataset
./run_50m_benchmark.escript --target 100000 --workers 5 --map-size 1G

echo ""
echo "To run the full 50M benchmark, use:"
echo "  ./run_50m_benchmark.escript"
echo ""
echo "For sequential keys (better space efficiency):"
echo "  ./run_50m_benchmark.escript --sequential"
echo ""
echo "For custom configuration:"
echo "  ./run_50m_benchmark.escript --help"