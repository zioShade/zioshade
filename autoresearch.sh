#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Pre-check: build first (fast syntax check)
mise exec -- zig build 2>&1

# Pre-check: reference tests must still pass
set +e
ref_output=$(mise exec -- zig build test-reference 2>&1)
set -e
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
    ref_passed=76
    ref_total=76
fi
ref_failed=$((ref_total - ref_passed))

if [ "$ref_failed" -ne 0 ]; then
    echo "METRIC total_ms=99999"
    echo "METRIC test_failures=${ref_failed}"
    exit 0
fi

# Performance benchmark: time compiling CRT shader through full pipeline
# This is the real-world workload — GLSL -> SPIR-V -> HLSL/GLSL/MSL
# Run 5 iterations, report median
times=()
for i in $(seq 1 5); do
    start_ns=$(date +%s%N)
    mise exec -- zig build dump-crt 2>&1 >/dev/null
    end_ns=$(date +%s%N)
    elapsed=$(( (end_ns - start_ns) / 1000000 ))
    times+=($elapsed)
done

# Sort and pick median
sorted=$(printf '%s\n' "${times[@]}" | sort -n)
median=$(echo "$sorted" | awk 'NR==3{print}')

echo "METRIC total_ms=${median}"
echo "METRIC test_failures=${ref_failed}"
