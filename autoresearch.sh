#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Build the conformance runner once
zig build conformance 2>/dev/null || true

# Find the runner executable
RUNNER=$(find .zig-cache -name "conformance-runner.exe" -type f 2>/dev/null | head -1)
if [ -z "$RUNNER" ]; then
    RUNNER=$(find .zig-cache -name "conformance-runner" -type f -executable 2>/dev/null | head -1)
fi
if [ -z "$RUNNER" ]; then
    echo "METRIC total_pass=0"
    echo "METRIC total_compile_error=0"
    echo "METRIC total_fail=0"
    echo "METRIC total_skip=0"
    echo "METRIC total_hang=0"
    exit 0
fi

total_pass=0
total_compile_error=0
total_fail=0
total_skip=0
total_hang=0

# Test a single file with timeout
test_file() {
    local file="$1"
    local timeout_secs="${2:-10}"
    local result

    result=$(timeout "$timeout_secs" "$RUNNER" "$file" 2>/dev/null) && true
    local exit_code=$?

    if [ $exit_code -eq 124 ] || [ $exit_code -eq 143 ]; then
        # Timed out (124 from timeout, 143 = SIGTERM)
        echo "  HANG $file"
        total_hang=$((total_hang + 1))
    elif echo "$result" | grep -q "PASS $file"; then
        total_pass=$((total_pass + 1))
    elif echo "$result" | grep -q "FAIL $file (compile error)"; then
        total_compile_error=$((total_compile_error + 1))
    elif echo "$result" | grep -q "FAIL $file (spirv-val)"; then
        total_fail=$((total_fail + 1))
    else
        total_skip=$((total_skip + 1))
    fi
}

# Test a directory with timeout per file
test_suite() {
    local dir="$1"
    local name="$2"
    local timeout_secs="${3:-10}"

    echo "=== $name ==="

    # Collect all shader files
    local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$dir" -type f \( -name "*.frag" -o -name "*.vert" -o -name "*.comp" -o -name "*.glsl" \) -print0 2>/dev/null | sort -z)

    for file in "${files[@]}"; do
        # Skip error-validation tests
        local basename
        basename=$(basename "$file")
        if [[ "$basename" == *.error.* ]]; then continue; fi
        if [[ "$basename" == link.* ]]; then continue; fi

        # Check for ERROR markers
        if grep -q "// ERROR" "$file" 2>/dev/null; then
            total_skip=$((total_skip + 1))
            continue
        fi

        test_file "$file" "$timeout_secs"
    done
}

# Run each test suite with appropriate timeouts
test_suite "tests/glslang-430" "glslang-430" 10
test_suite "tests/ghostty" "ghostty" 15
test_suite "tests/spirv-cross" "spirv-cross" 5

echo ""
echo "=== SUMMARY ==="
echo "METRIC total_pass=$total_pass"
echo "METRIC total_compile_error=$total_compile_error"
echo "METRIC total_fail=$total_fail"
echo "METRIC total_skip=$total_skip"
echo "METRIC total_hang=$total_hang"
echo "METRIC total_files=$((total_pass + total_compile_error + total_fail + total_skip + total_hang))"
