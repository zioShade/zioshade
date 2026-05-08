#!/bin/bash
set -o pipefail
cd "$(dirname "$0")"
ZIG="C:/Users/Alessandro/scoop/apps/zig/0.15.2/zig.exe"
OUTPUT=$($ZIG build test-hlsl 2>&1)
echo "$OUTPUT"
# Extract pass/fail counts
PASSED=$(echo "$OUTPUT" | grep -Eo '[0-9]+/[0-9]+ tests passed' | head -1 | grep -Eo '^[0-9]+' | head -1)
if [ -z "$PASSED" ]; then
    PASSED=$(echo "$OUTPUT" | grep -Eo '[0-9]+ passed' | head -1 | grep -Eo '[0-9]+')
fi
FAILED=$(echo "$OUTPUT" | grep -Eo '[0-9]+ tests passed' | head -1 | grep -Eo 'failed' | head -1 || echo "0")
if [ "$FAILED" = "failed" ]; then
    FAILED=$(echo "$OUTPUT" | grep -E '[0-9]+ failed' | grep 'tests' | head -1 | grep -Eo '[0-9]+' | head -1)
fi
if [ -z "$FAILED" ]; then
    FAILED=0
fi
LEAKED=$(echo "$OUTPUT" | grep -Eo '[0-9]+ leaked' | head -1 | grep -Eo '[0-9]+')
echo ""
echo "METRIC tests_passed=${PASSED:-0}"
echo "METRIC tests_failed=${FAILED:-0}"
echo "METRIC tests_leaked=${LEAKED:-0}"
