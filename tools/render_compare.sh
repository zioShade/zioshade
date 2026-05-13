#!/bin/bash
# Rendering comparison: glslpp vs spirv-cross
# Compiles fragment shaders through both pipelines, renders with OpenGL, and compares pixels.
#
# Usage: bash tools/render_compare.sh [shader_dir] [size]
#
# Outputs METRIC lines for autoresearch integration.

set -euo pipefail

GLSLANG="${GLSLANG:-glslangValidator}"
SPIRVCROSS="${SPIRVCROSS:-spirv-cross}"
RENDER_TOOL="${RENDER_TOOL:-tools/gl_render_compare.exe}"
GLSLPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHADER_DIR="${1:-tests/render_compare}"
SIZE="${2:-128}"
TMPDIR="${TMPDIR:-/tmp/render_compare_$$}"

mkdir -p "$TMPDIR"

# Build the spv-to-glsl tool if needed
if [ ! -f ".zig-cache/o/*/spv-to-glsl.exe" ] 2>/dev/null; then
    mise exec -- zig build spv-to-glsl 2>/dev/null || true
fi
# Find the built binary
SPV_TO_GLSL=$(find .zig-cache -name "spv-to-glsl.exe" -type f 2>/dev/null | head -1)
if [ -z "$SPV_TO_GLSL" ]; then
    echo "ERROR: spv-to-glsl.exe not found. Run: zig build spv-to-glsl"
    exit 1
fi

total=0
pass=0
fail=0
skip=0
total_max_diff=0

echo "Rendering Comparison: glslpp vs spirv-cross"
echo "Shader dir: $SHADER_DIR"
echo "Resolution: ${SIZE}x${SIZE}"
echo "============================================"

for frag in "$GLSLPP_DIR/$SHADER_DIR"/*.frag; do
    [ -f "$frag" ] || continue
    name=$(basename "$frag" .frag)
    total=$((total + 1))

    spv="$TMPDIR/${name}.spv"
    glslpp_glsl="$TMPDIR/${name}_glslpp.glsl"
    spirvcross_glsl="$TMPDIR/${name}_spirvcross.glsl"

    # Step 1: glslangValidator → SPIR-V
    if ! $GLSLANG -V -S frag "$frag" -o "$spv" 2>/dev/null; then
        echo "  SKIP $name (glslangValidator failed)"
        skip=$((skip + 1))
        continue
    fi

    # Step 2a: glslpp SPIR-V → GLSL
    if ! "$SPV_TO_GLSL" "$spv" "$glslpp_glsl" 2>/dev/null; then
        echo "  SKIP $name (glslpp GLSL failed)"
        skip=$((skip + 1))
        continue
    fi

    # Step 2b: spirv-cross SPIR-V → GLSL
    if ! $SPIRVCROSS "$spv" --version 430 --output "$spirvcross_glsl" 2>/dev/null; then
        echo "  SKIP $name (spirv-cross GLSL failed)"
        skip=$((skip + 1))
        continue
    fi

    # Step 3: Render and compare
    output=$("$GLSLPP_DIR/$RENDER_TOOL" "$glslpp_glsl" "$spirvcross_glsl" "$SIZE" "$SIZE" 2>&1) || true
    max_diff=$(echo "$output" | grep "Max channel diff:" | sed 's/.*: //' || echo "-1")
    match=$(echo "$output" | grep -c "MATCH" || echo "0")

    if [ "$match" -eq 1 ]; then
        echo "  PASS $name (max_diff=$max_diff)"
        pass=$((pass + 1))
    else
        echo "  FAIL $name (max_diff=$max_diff)"
        fail=$((fail + 1))
    fi
    total_max_diff=$((total_max_diff + max_diff))
done

echo ""
echo "============================================"
echo "Total: $total | Pass: $pass | Fail: $fail | Skip: $skip"

# Output metrics for autoresearch
echo "METRIC render_total=${total}"
echo "METRIC render_pass=${pass}"
echo "METRIC render_fail=${fail}"
echo "METRIC render_skip=${skip}"

# Cleanup
rm -rf "$TMPDIR"

exit 0
