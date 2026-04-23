#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

GLSLANG="C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"

# Build runner
echo "Building..." >&2
timeout 120 zig build conformance -- nul 2>/dev/null || true
RUNNER=$(find .zig-cache -name "conformance-runner.exe" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$RUNNER" ]; then echo "ERROR: no runner"; echo "METRIC total_pass=0"; exit 0; fi
echo "Runner: $RUNNER" >&2

# Phase 1: classify with glslangValidator (cached)
CACHE=".zig-cache/ref_classification.txt"
if [ ! -f "$CACHE" ]; then
    echo "Classifying files with glslangValidator..." >&2
    > "$CACHE"
    for dir in tests/glslang-430 tests/ghostty tests/spirv-cross; do
        while IFS= read -r -d '' file; do
            bn=$(basename "$file")
            # Skip known error/intentional-failure files
            case "$bn" in
                *.error.*) echo "SKIP $file" >> "$CACHE"; continue ;;
                link.*)    echo "SKIP $file" >> "$CACHE"; continue ;;
            esac
            grep -q "// ERROR" "$file" 2>/dev/null && { echo "SKIP $file" >> "$CACHE"; continue; }
            # common.glsl is an include file, not standalone
            [ "$bn" = "common.glsl" ] && { echo "SKIP $file" >> "$CACHE"; continue; }
            
            # glslangValidator: for .glsl files, infer stage from name
            glslang_args=()
            case "$bn" in
                *.f.glsl) glslang_args=(-S frag) ;;
                *.v.glsl) glslang_args=(-S vert) ;;
                *.c.glsl) glslang_args=(-S comp) ;;
            esac

            if "$GLSLANG" "${glslang_args[@]}" "$file" >/dev/null 2>&1; then
                echo "VALID $file" >> "$CACHE"
            else
                echo "INVALID $file" >> "$CACHE"
            fi
        done < <(find "$dir" -type f \( -name "*.frag" -o -name "*.vert" -o -name "*.comp" -o -name "*.glsl" \) -print0 2>/dev/null | sort -z)
    done
    echo "Classification done." >&2
fi

ref_valid=$(grep -c "^VALID" "$CACHE" || true)
ref_invalid=$(grep -c "^INVALID" "$CACHE" || true)
ref_skip=$(grep -c "^SKIP" "$CACHE" || true)
total_all=$((ref_valid + ref_invalid + ref_skip))
echo "Files: $total_all total | $ref_valid valid | $ref_invalid invalid | $ref_skip skipped" >&2

# Phase 2: test our compiler against valid files only
our_pass=0
our_cerr=0
our_sval=0
our_hang=0
our_crash=0

while IFS=' ' read -r status file; do
    [ "$status" != "VALID" ] && continue
    [ -z "$file" ] && continue

    exit_code=0
    output=$(timeout 2 "$RUNNER" "$file" 2>&1) || exit_code=$?

    if [ $exit_code -eq 124 ]; then
        our_hang=$((our_hang + 1))
        continue
    fi

    # Detect crashes (segfault, double-free, etc) — non-zero exit with no PASS/FAIL
    has_pass=0; has_cerr=0; has_sval=0
    echo "$output" | grep -qE "^  PASS " && has_pass=1 || true
    echo "$output" | grep -qE "^  FAIL .*compile error" && has_cerr=1 || true
    echo "$output" | grep -qE "^  FAIL .*spirv-val" && has_sval=1 || true

    if [ $has_pass -eq 1 ] && [ $exit_code -eq 0 ]; then
        our_pass=$((our_pass + 1))
    elif [ $has_sval -eq 1 ]; then
        our_sval=$((our_sval + 1))
    elif [ $has_cerr -eq 1 ]; then
        our_cerr=$((our_cerr + 1))
    elif [ $has_pass -eq 1 ] && [ $exit_code -ne 0 ]; then
        # PASS reported but runner crashed — false positive
        our_crash=$((our_crash + 1))
    elif [ $exit_code -ne 0 ]; then
        our_crash=$((our_crash + 1))
    else
        our_cerr=$((our_cerr + 1))
    fi
done < "$CACHE"

echo "" >&2
echo "=== OUR COMPILER vs $ref_valid valid test files ===" >&2
echo "PASS:           $our_pass" >&2
echo "COMPILE ERROR:  $our_cerr" >&2
echo "SPIRV-VAL FAIL: $our_sval" >&2
echo "HANG:           $our_hang" >&2
echo "CRASH:          $our_crash" >&2

echo "METRIC total_pass=$our_pass"
echo "METRIC total_compile_error=$our_cerr"
echo "METRIC total_fail=$our_sval"
echo "METRIC total_hang=$our_hang"
echo "METRIC total_crash=$our_crash"
echo "METRIC ref_valid=$ref_valid"
echo "METRIC total_tested=$((our_pass + our_cerr + our_sval + our_hang + our_crash))"
