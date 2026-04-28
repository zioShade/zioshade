#!/bin/bash
# Compare our SPIR-V output against glslangValidator for a single shader
# Outputs structured metrics about the differences
set -uo pipefail

GLSLANG="C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"
SPV_DIS="C:/VulkanSDK/1.4.341.1/Bin/spirv-dis.exe"
RUNNER=".zig-cache/bin/conformance-runner.exe"

file="$1"
bn=$(basename "$file")

# Stage detection
glslang_args=("-V")
case "$bn" in
    *.f.glsl) glslang_args+=(-S frag) ;;
    *.v.glsl) glslang_args+=(-S vert) ;;
    *.c.glsl) glslang_args+=(-S comp) ;;
esac

# Compile with both
if ! "$GLSLANG" "${glslang_args[@]}" "$file" -o /tmp/ref.spv 2>/dev/null; then
    echo "METRIC ref_compile=fail"
    exit 0
fi

if ! output=$(timeout 2 "$RUNNER" --save-spv /tmp/our.spv "$file" 2>&1) || ! echo "$output" | grep -q "PASS"; then
    echo "METRIC our_compile=fail"
    exit 0
fi

# Both valid — extract metrics
ref_dis=$("$SPV_DIS" /tmp/ref.spv 2>/dev/null)
our_dis=$("$SPV_DIS" /tmp/our.spv 2>/dev/null)

ref_bound=$(echo "$ref_dis" | grep 'Bound:' | grep -oE '[0-9]+')
our_bound=$(echo "$our_dis" | grep 'Bound:' | grep -oE '[0-9]+')

ref_vars=$(echo "$ref_dis" | grep -c 'OpVariable')
our_vars=$(echo "$our_dis" | grep -c 'OpVariable')

ref_caps=$(echo "$ref_dis" | grep -c 'OpCapability')
our_caps=$(echo "$ref_dis" | grep -c 'OpCapability')

ref_entry_vars=$(echo "$ref_dis" | grep 'OpEntryPoint' | grep -oE '%[a-zA-Z_][a-zA-Z0-9_]*' | wc -l)
our_entry_vars=$(echo "$our_dis" | grep 'OpEntryPoint' | grep -oE '%[a-zA-Z_][a-zA-Z0-9_]*' | wc -l)

echo "METRIC ref_compile=pass"
echo "METRIC our_compile=pass"
echo "METRIC ref_bound=$ref_bound"
echo "METRIC our_bound=$our_bound"
echo "METRIC ref_vars=$ref_vars"
echo "METRIC our_vars=$our_vars"
echo "METRIC ref_caps=$ref_caps"
echo "METRIC our_caps=$our_caps"
echo "METRIC ref_entry_vars=$ref_entry_vars"
echo "METRIC our_entry_vars=$our_entry_vars"

# Check if computation is identical by comparing function bodies (strip names/IDs)
ref_body=$(echo "$ref_dis" | sed -n '/OpFunction %void/,/OpFunctionEnd/p' | grep -v 'OpName\|OpMemberName\|OpLabel\|%[0-9]*\|%[a-zA-Z]' | grep -v '^$' | grep -v '^;' | sort)
our_body=$(echo "$our_dis" | sed -n '/OpFunction %void/,/OpFunctionEnd/p' | grep -v 'OpName\|OpMemberName\|OpLabel\|%[0-9]*\|%[a-zA-Z]' | grep -v '^$' | grep -v '^;' | sort)

if [ "$ref_body" = "$our_body" ]; then
    echo "METRIC body_match=1"
else
    echo "METRIC body_match=0"
fi
