#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Pre-check: build first (fast syntax check)
mise exec -- zig build 2>&1

# Run core tests (must always pass)
core_result=$(mise exec -- zig test src/root.zig 2>&1)
core_passed=$(echo "$core_result" | grep -oP '\d+(?=/d+ tests passed)' || echo "0")
core_total=$(echo "$core_result" | grep -oP '(?<=/)\d+(?= tests passed)' || echo "1")
if [ "$core_passed" != "$core_total" ]; then
    echo "METRIC test_failures=999"
    echo "METRIC build_ms=0"
    exit 0
fi

# Run reference tests — count failures
ref_output=$(mise exec -- zig build test-reference 2>&1) || true
ref_passed=$(echo "$ref_output" | grep -oP '\d+(?=/\d+ tests passed)' || echo "0")
ref_total=$(echo "$ref_output" | grep -oP '(?<=/)\d+(?= tests passed)' || echo "76")
ref_failed=$((ref_total - ref_passed))

# Time the test run
start_ms=$(date +%s%N | cut -b1-13)
mise exec -- zig build test-reference 2>&1 >/dev/null || true
end_ms=$(date +%s%N | cut -b1-13)
build_ms=$((end_ms - start_ms))

echo "METRIC test_failures=${ref_failed}"
echo "METRIC build_ms=${build_ms}"
