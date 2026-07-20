#!/usr/bin/env bash
# stage_pairs.sh — emit zioshade + SPIRV-Cross HLSL pairs for the WARP render check.
#
# For each GLSL shader, writes into the staging dir:
#     <name>.zs.hlsl   zioshade  GLSL -> HLSL
#     <name>.sc.hlsl   reference GLSL -> (zioshade SPIR-V) -> spirv-cross -> HLSL
# both from the identical GLSL, so run.ps1 on Windows renders zioshade's HLSL
# against the reference cross-compiler's HLSL on the real DXC->DXIL->D3D12 path.
# Copy the staging dir (plus tools/warp/) to the Windows box and run run.ps1 there.
#
# Optionally pass a newline list of shader base-names (e.g. the macOS RENDER-MATCH
# set from tools/hlsl_render_check.sh --sweep) as $3 to stage only that subset.
#
# Usage: tools/warp/stage_pairs.sh <out_dir> [glsl_dir] [names_file]
set -uo pipefail
cd "$(dirname "$0")/../.."

OUT=${1:?usage: stage_pairs.sh <out_dir> [glsl_dir] [names_file]}
DIR=${2:-tests/spirv-cross}
NAMES=${3:-}
CLI=${CLI:-zig-out/bin/zioshade}
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
mkdir -p "$OUT"

staged=0
for f in "$DIR"/*.frag; do
  case "$f" in *.asm.*) continue;; esac
  [ -e "$f" ] || continue
  name=$(basename "$f" .frag)
  if [ -n "$NAMES" ] && ! grep -qxF "$name" "$NAMES"; then continue; fi
  # zioshade HLSL
  "$CLI" hlsl "$f" --stage fragment > "$OUT/$name.zs.hlsl" 2>/dev/null || { rm -f "$OUT/$name.zs.hlsl"; continue; }
  # reference: zioshade SPIR-V -> spirv-cross HLSL
  "$CLI" compile "$f" --stage fragment -o "$OUT/$name.spv" 2>/dev/null || { rm -f "$OUT/$name.zs.hlsl" "$OUT/$name.spv"; continue; }
  spirv-cross --hlsl --shader-model 60 "$OUT/$name.spv" > "$OUT/$name.sc.hlsl" 2>/dev/null || { rm -f "$OUT/$name.zs.hlsl" "$OUT/$name.sc.hlsl" "$OUT/$name.spv"; continue; }
  rm -f "$OUT/$name.spv"
  staged=$((staged+1))
done
cp tools/warp/fullscreen_vs.hlsl "$OUT/" 2>/dev/null || true
echo "staged $staged shader pairs into $OUT"
echo "next: copy $OUT + tools/warp/{warp_render.cpp,run.ps1,README.md} to the Windows box, build warp_render.exe, run: .\\run.ps1 -Dir <copied_dir>"
