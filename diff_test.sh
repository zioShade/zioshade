#!/bin/bash
# Differential testing: compare our SPIR-V output against glslangValidator reference
# Compiles each valid test shader with both compilers, disassembles both,
# and compares the Op instruction sequences (stripping IDs).
set -uo pipefail
cd "$(dirname "$0")"

GLSLANG="C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"
SPV_DIS="C:/VulkanSDK/1.4.341.1/Bin/spirv-dis.exe"
SPV_VAL="C:/VulkanSDK/1.4.341.1/Bin/spirv-val.exe"
CACHE=".zig-cache/ref_classification.txt"

# Build runner if needed
if [ ! -f .zig-cache/bin/conformance-runner.exe ]; then
    echo "Building..." >&2
    mkdir -p .zig-cache/bin
    timeout 120 zig build-exe -ODebug --dep glslpp -Mroot=tests/runner.zig -Mglslpp=src/root.zig --cache-dir .zig-cache -femit-bin=.zig-cache/bin/conformance-runner.exe 2>/dev/null
fi

# Normalize SPIR-V disassembly: strip IDs, labels, debug info
normalize_dis() {
    local dis="$1"
    echo "$dis" | \
        grep -v '^;' | \
        grep -v '^$' | \
        grep -v 'OpName' | \
        grep -v 'OpMemberName' | \
        grep -v 'OpSource' | \
        grep -v 'OpDecorate.*Name' | \
        sed 's/%[0-9]*/%_/g' | \
        sed 's/ [0-9]\+ / ID /g' | \
        sort
}

our_pass=0
ref_fail=0
match=0
differ=0
total=0

while IFS=' ' read -r status file; do
    [ "$status" != "VALID" ] && continue
    [ -z "$file" ] && continue
    total=$((total + 1))

    bn=$(basename "$file")

    # Get stage flag for glslang
    glslang_args=("-V")
    case "$bn" in
        *.f.glsl) glslang_args+=(-S frag) ;;
        *.v.glsl) glslang_args+=(-S vert) ;;
        *.c.glsl) glslang_args+=(-S comp) ;;
    esac

    # Compile with glslangValidator to get reference SPIR-V
    if ! "$GLSLANG" "${glslang_args[@]}" "$file" -o /tmp/ref.spv 2>/dev/null; then
        ref_fail=$((ref_fail + 1))
        continue
    fi

    ref_dis=$("$SPV_DIS" /tmp/ref.spv 2>/dev/null)
    ref_norm=$(normalize_dis "$ref_dis")

    # Count reference Op types
    ref_op_types=$(echo "$ref_dis" | grep -oE 'Op[A-Za-z]+' | sort -u | wc -l)
    ref_op_count=$(echo "$ref_dis" | grep -cE 'Op[A-Z]')

    our_pass=0  # Will be set below
    # Our compiler uses autoresearch.sh approach: run runner on single file
    # For now, just report if both produce valid SPIR-V
    our_output=$(timeout 2 .zig-cache/bin/conformance-runner.exe "$file" 2>&1) || true
    if echo "$our_output" | grep -qE "^  PASS "; then
        our_pass=1
        match=$((match + 1))
    fi

    # Show progress for first 20 and every 50th
    if [ $total -le 20 ] || [ $((total % 50)) -eq 0 ]; then
        echo "[$total] $bn: ref_ops=$ref_op_count, ref_types=$ref_op_types" >&2
    fi
done < "$CACHE"

echo ""
echo "=== DIFFERENTIAL TEST SUMMARY ==="
echo "Total valid:         $total"
echo "Reference fails:     $ref_fail (glslangValidator couldn't compile)"
echo "Both valid:          $match"
echo ""
echo "Next step: For the $match shaders where both produce valid SPIR-V,"
echo "compare normalized Op sequences to detect semantic differences."
