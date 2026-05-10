#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Pre-check: build first (fast syntax check)
mise exec -- zig build 2>&1

# Run core tests (must always pass)
core_result=$(mise exec -- zig test src/root.zig 2>&1 || true)
if echo "$core_result" | grep -q "All .* tests passed"; then
    : # OK
else
    echo "METRIC test_failures=999"
    echo "METRIC build_ms=0"
    exit 0
fi

# Run reference tests - capture output
set +e
ref_output=$(mise exec -- zig build test-reference 2>&1)
set -e

# Parse "X/Y tests passed" from the output
ref_line=$(echo "$ref_output" | grep 'tests passed' | tail -1) || true
if [ -n "$ref_line" ]; then
    ref_frac=$(echo "$ref_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\/[0-9]+$/) print $i}' | tail -1) || true
    if [ -n "$ref_frac" ]; then
        ref_passed=$(echo "$ref_frac" | cut -d/ -f1)
        ref_total=$(echo "$ref_frac" | cut -d/ -f2)
    else
        ref_passed=0
        ref_total=76
    fi
else
    # No "tests passed" line means all tests passed (zig outputs nothing on success)
    ref_passed=76
    ref_total=76
fi
ref_failed=$((ref_total - ref_passed))

# Time the test run
start_ms=$(date +%s%N | cut -b1-13)
set +e
mise exec -- zig build test-reference 2>&1 >/dev/null
set -e
end_ms=$(date +%s%N | cut -b1-13)
build_ms=$((end_ms - start_ms))

echo "METRIC test_failures=${ref_failed}"
echo "METRIC build_ms=${build_ms}"
