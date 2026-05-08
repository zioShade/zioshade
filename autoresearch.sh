#!/bin/bash
set -o pipefail
cd "$(dirname "$0")"
ZIG="C:/Users/Alessandro/scoop/apps/zig/0.15.2/zig.exe"
OUTPUT=$($ZIG build test-hlsl --summary all 2>&1)
echo "$OUTPUT"
# Extract pass/fail counts from various output formats
# Format 1: "N/M passed, K failed" (on failure)
# Format 2: "N/M tests passed; K failed" (on failure with details)
# Format 3: "N passed" (on success with --summary)
PASSED=$(echo "$OUTPUT" | grep -Eo '[0-9]+/[0-9]+ (tests )?passed' | head -1 | grep -Eo '^[0-9]+' | head -1)
if [ -z "$PASSED" ]; then
    PASSED=$(echo "$OUTPUT" | grep -Eo '[0-9]+ passed' | head -1 | grep -Eo '[0-9]+')
fi
if [ -z "$PASSED" ]; then
    PASSED=0
fi
FAILED=$(echo "$OUTPUT" | grep -Eo '[0-9]+ failed' | head -1 | grep -Eo '[0-9]+' | head -1)
if [ -z "$FAILED" ]; then
    FAILED=0
fi
LEAKED=$(echo "$OUTPUT" | grep -Eo '[0-9]+ leaked' | head -1 | grep -Eo '[0-9]+')
echo ""
echo "METRIC tests_passed=${PASSED:-0}"
echo "METRIC tests_failed=${FAILED:-0}"
echo "METRIC tests_leaked=${LEAKED:-0}"
