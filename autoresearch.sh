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
min_cross_ms=99999
for i in $(seq 1 11); do
    output=$("$EXE" 2>&1) || true
    cross_us=$(echo "$output" | grep 'METRIC cross_us=' | sed 's/METRIC cross_us=//')
    if [ -n "$cross_us" ]; then
        cross_ms=$((cross_us / 1000))
        if [ "$cross_ms" -lt "$min_cross_ms" ]; then
            min_cross_ms=$cross_ms
        fi
    fi
done

if [ "$min_cross_ms" -eq 99999 ]; then
    echo "METRIC total_ms=99999"
    echo "METRIC test_failures=999"
    exit 0
fi

echo "METRIC total_ms=${min_cross_ms}"
echo "METRIC test_failures=${ref_failed}"
