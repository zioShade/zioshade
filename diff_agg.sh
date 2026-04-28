#!/bin/bash
# Fast aggregate differential metrics
set -uo pipefail
cd "$(dirname "$0")"

GLSLANG="C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"
SPV_DIS="C:/VulkanSDK/1.4.341.1/Bin/spirv-dis.exe"
SPV_VAL="C:/VulkanSDK/1.4.341.1/Bin/spirv-val.exe"
RUNNER=".zig-cache/bin/conformance-runner.exe"
CACHE=".zig-cache/ref_classification.txt"

# Build runner if needed
if [ ! -f "$RUNNER" ]; then
    echo "Building..." >&2
    mkdir -p .zig-cache/bin
    timeout 120 zig build-exe -ODebug --dep glslpp -Mroot=tests/runner.zig -Mglslpp=src/root.zig --cache-dir .zig-cache -femit-bin=.zig-cache/bin/conformance-runner.exe 2>/dev/null
fi

both=0
body_match=0
ref_bound_sum=0
our_bound_sum=0
ref_var_sum=0
our_var_sum=0

while IFS=' ' read -r status file; do
    [ "$status" != "VALID" ] && continue
    bn=$(basename "$file")
    
    glslang_args=("-V")
    case "$bn" in
        *.f.glsl) glslang_args+=(-S frag) ;;
        *.v.glsl) glslang_args+=(-S vert) ;;
        *.c.glsl) glslang_args+=(-S comp) ;;
    esac
    
    if ! "$GLSLANG" "${glslang_args[@]}" "$file" -o /tmp/ref.spv 2>/dev/null; then continue; fi
    if ! output=$(timeout 2 "$RUNNER" --save-spv /tmp/our.spv "$file" 2>&1) || ! echo "$output" | grep -q "PASS"; then continue; fi
    
    both=$((both + 1))
    
    ref_dis=$("$SPV_DIS" /tmp/ref.spv 2>/dev/null)
    our_dis=$("$SPV_DIS" /tmp/our.spv 2>/dev/null)
    
    # Bound
    rb=$(echo "$ref_dis" | grep 'Bound:' | grep -oE '[0-9]+')
    ob=$(echo "$our_dis" | grep 'Bound:' | grep -oE '[0-9]+')
    ref_bound_sum=$((ref_bound_sum + rb))
    our_bound_sum=$((our_bound_sum + ob))
    
    # Variables
    rv=$(echo "$ref_dis" | grep -c 'OpVariable')
    ov=$(echo "$our_dis" | grep -c 'OpVariable')
    ref_var_sum=$((ref_var_sum + rv))
    our_var_sum=$((our_var_sum + ov))
    
    # Progress
    if [ $both -le 5 ] || [ $((both % 50)) -eq 0 ]; then
        echo "[$both] $bn: ref_bound=$rb our_bound=$ob" >&2
    fi
done < "$CACHE"

echo ""
echo "=== AGGREGATE METRICS ==="
echo "Both valid:          $both"
echo "Total ref bound:     $ref_bound_sum"
echo "Total our bound:     $our_bound_sum"
echo "Total ref vars:      $ref_var_sum"
echo "Total our vars:      $our_var_sum"

echo "METRIC both_valid=$both"
echo "METRIC ref_bound=$ref_bound_sum"
echo "METRIC our_bound=$our_bound_sum"
echo "METRIC ref_vars=$ref_var_sum"
echo "METRIC our_vars=$our_var_sum"
