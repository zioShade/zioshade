#!/bin/bash
# Benchmark: count store mismatches between our output and glslang's
# Store mismatch = different number of output stores (OpStore to FragColor/out_var/frag_color)
set -uo pipefail
cd "$(dirname "$0")"

GLSLANG="C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"
SPV_DIS="C:/VulkanSDK/1.4.341.1/Bin/spirv-dis.exe"
RUNNER=".zig-cache/bin/conformance-runner.exe"
CACHE=".zig-cache/ref_classification.txt"

# Build runner if needed
if [ ! -f "$RUNNER" ]; then
    echo "Building..." >&2
    mkdir -p .zig-cache/bin
    timeout 120 zig build-exe -OReleaseSafe --dep glslpp -Mroot=tests/runner.zig -Mglslpp=src/root.zig --cache-dir .zig-cache -femit-bin=.zig-cache/bin/conformance-runner.exe 2>/dev/null || true
fi
if [ ! -f "$RUNNER" ]; then echo "ERROR: no runner"; echo "METRIC store_mismatches=999"; exit 0; fi

mismatches=0
total=0
pass=0

while IFS=' ' read -r status file; do
    [ "$status" != "VALID" ] && continue
    [ -z "$file" ] && continue
    total=$((total + 1))
    bn=$(basename "$file")

    # Get stage flag
    glslang_args=("-V")
    case "$bn" in
        *.f.glsl) glslang_args+=(-S frag) ;;
        *.v.glsl) glslang_args+=(-S vert) ;;
        *.c.glsl) glslang_args+=(-S comp) ;;
    esac

    # Compile with both
    "$GLSLANG" "${glslang_args[@]}" "$file" -o /tmp/ref_mm.spv 2>/dev/null || continue
    output=$(timeout 2 "$RUNNER" --save-spv /tmp/our_mm.spv "$file" 2>&1) || continue
    echo "$output" | grep -q "PASS" || continue
    pass=$((pass + 1))

    # Count output stores in both
    ref_stores=$("$SPV_DIS" /tmp/ref_mm.spv 2>/dev/null | grep -c "OpStore.*FragColor\|OpStore.*out_var\|OpStore.*frag_color\|OpStore.*pc_fragColor\|OpStore.*result")
    our_stores=$("$SPV_DIS" /tmp/our_mm.spv 2>/dev/null | grep -c "OpStore.*FragColor\|OpStore.*out_var\|OpStore.*frag_color\|OpStore.*pc_fragColor\|OpStore.*result")

    if [ "$ref_stores" != "$our_stores" ] && [ "$ref_stores" -gt 0 ]; then
        mismatches=$((mismatches + 1))
        if [ $mismatches -le 20 ]; then
            echo "MISMATCH: $bn our=$our_stores ref=$ref_stores" >&2
        fi
    fi

    if [ $total -le 5 ] || [ $((total % 50)) -eq 0 ]; then
        echo "[$total] pass=$pass mismatches=$mismatches" >&2
    fi
done < "$CACHE"

echo "" >&2
echo "=== STORE MISMATCH RESULTS ===" >&2
echo "Total valid: $total, Both pass: $pass, Mismatches: $mismatches" >&2
echo "METRIC store_mismatches=$mismatches"
echo "METRIC both_pass=$pass"
echo "METRIC total_valid=$total"
