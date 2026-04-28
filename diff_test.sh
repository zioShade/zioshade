#!/bin/bash
# Differential testing: compare our SPIR-V output against glslangValidator reference
# Compiles each valid test shader with both compilers, disassembles both,
# normalizes, and compares the Op instruction sequences.
set -uo pipefail
cd "$(dirname "$0")"

GLSLANG="C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"
SPV_DIS="C:/VulkanSDK/1.4.341.1/Bin/spirv-dis.exe"
SPV_VAL="C:/VulkanSDK/1.4.341.1/Bin/spirv-val.exe"
CACHE=".zig-cache/ref_classification.txt"
RUNNER=".zig-cache/bin/conformance-runner.exe"

# Build runner if needed
if [ ! -f "$RUNNER" ]; then
    echo "Building..." >&2
    mkdir -p .zig-cache/bin
    timeout 120 zig build-exe -ODebug --dep glslpp -Mroot=tests/runner.zig -Mglslpp=src/root.zig --cache-dir .zig-cache -femit-bin=.zig-cache/bin/conformance-runner.exe 2>/dev/null
fi

# Normalize SPIR-V disassembly: strip IDs, debug info, comments, blank lines
normalize_dis() {
    local dis="$1"
    echo "$dis" | \
        grep -v '^;' | \
        grep -v '^$' | \
        grep -v 'OpName' | \
        grep -v 'OpMemberName' | \
        grep -v 'OpSource' | \
        grep -v 'OpSourceExtension' | \
        grep -v 'OpString' | \
        grep -v 'OpModuleProcessed' | \
        grep -v 'OpLine' | \
        grep -v 'OpNoLine' | \
        sed 's/%[a-zA-Z_][a-zA-Z0-9_]*/%_/g' | \
        sed 's/%[0-9]*/%id/g' | \
        sed 's/  */ /g' | \
        sed 's/^ //' | \
        sort
}

# Extract just the Op types (for quick structural comparison)
op_types() {
    local dis="$1"
    echo "$dis" | grep -oE 'Op[A-Za-z]+' | sort | uniq -c | sort -rn
}

ref_fail=0
our_fail=0
match=0
structural_diff=0
total=0

mkdir -p .zig-cache/diff

while IFS=' ' read -r status file; do
    [ "$status" != "VALID" ] && continue
    [ -z "$file" ] && continue
    total=$((total + 1))

    bn=$(basename "$file")
    name="${bn%.*}"

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

    # Compile with our compiler
    output=$(timeout 2 "$RUNNER" --save-spv /tmp/our.spv "$file" 2>&1)
    if ! echo "$output" | grep -q "PASS"; then
        our_fail=$((our_fail + 1))
        continue
    fi

    # Both produced valid SPIR-V — disassemble and compare
    ref_dis=$("$SPV_DIS" /tmp/ref.spv 2>/dev/null)
    our_dis=$("$SPV_DIS" /tmp/our.spv 2>/dev/null)

    ref_norm=$(normalize_dis "$ref_dis")
    our_norm=$(normalize_dis "$our_dis")

    if [ "$ref_norm" = "$our_norm" ]; then
        match=$((match + 1))
    else
        structural_diff=$((structural_diff + 1))
        # Save diff for analysis
        diff <(echo "$ref_norm") <(echo "$our_norm") > ".zig-cache/diff/${name}.diff" 2>/dev/null

        # Count Op differences
        ref_ops=$(op_types "$ref_dis")
        our_ops=$(op_types "$our_dis")
        diff <(echo "$ref_ops") <(echo "$our_ops") > ".zig-cache/diff/${name}.ops.diff" 2>/dev/null
    fi

    # Show progress
    if [ $total -le 10 ] || [ $((total % 50)) -eq 0 ]; then
        echo "[$total] $bn: match=$match diff=$structural_diff" >&2
    fi
done < "$CACHE"

echo ""
echo "=== DIFFERENTIAL TEST SUMMARY ==="
echo "Total valid:            $total"
echo "Reference fails:        $ref_fail"
echo "Our compile fails:      $our_fail"
echo "Both valid:             $((match + structural_diff))"
echo "Normalized MATCH:       $match"
echo "STRUCTURAL_DIFF:        $structural_diff"
echo ""
echo "Diffs saved to: .zig-cache/diff/*.diff"
echo "  Op-type diffs: .zig-cache/diff/*.ops.diff"
echo ""
echo "To investigate differences:"
echo "  cat .zig-cache/diff/<name>.diff"
echo "  cat .zig-cache/diff/<name>.ops.diff"
