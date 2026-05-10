#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Pre-check: build in Debug mode (fast syntax check) + run reference tests
mise exec -- zig build 2>&1

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

# Build dump-crt in ReleaseFast for accurate performance measurement
mise exec -- zig build -Doptimize=ReleaseFast dump-crt 2>&1

# Find the ReleaseFast dump-crt binary (smallest exe = optimized, no debug info)
EXE=$(find .zig-cache -name "dump-crt.exe" -type f -printf '%s %p\n' | sort -n | head -1 | cut -d' ' -f2-)
if [ -z "$EXE" ]; then
    echo "METRIC total_ms=99999"
    echo "METRIC test_failures=999"
    exit 0
fi

# Performance benchmark: measure cross-compilation time (SPIR-V → HLSL+GLSL+MSL)
# Run 11 iterations, take minimum (most stable estimator for noisy benchmarks)
min_cross_us=999999999
for i in $(seq 1 11); do
    output=$("$EXE" 2>&1) || true
    cross_us=$(echo "$output" | grep 'METRIC cross_us=' | sed 's/METRIC cross_us=//')
    if [ -n "$cross_us" ]; then
        if [ "$cross_us" -lt "$min_cross_us" ]; then
            min_cross_us=$cross_us
        fi
    fi
done

if [ "$min_cross_us" -eq 999999999 ]; then
    echo "METRIC cross_total_us=999999999"
    echo "METRIC test_failures=999"
    exit 0
fi

echo "METRIC cross_total_us=${min_cross_us}"
echo "METRIC test_failures=${ref_failed}"
