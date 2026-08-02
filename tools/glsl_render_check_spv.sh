#!/usr/bin/env bash
# GLSL render proxy for BINARY SPIR-V inputs (.spv) -- the .spv counterpart of
# tools/glsl_render_check.sh (which starts from .frag). Verifies zioshade's GLSL
# output is RENDER-correct (not just glslang-valid) by round-tripping through
# Metal: source .spv ->(spirv-cross --msl)-> MSL_ref (render-proven path); and
# source .spv ->(zioshade glsl)-> z.glsl ->(glslang -V)-> z.spv ->(spirv-cross
# --msl)-> z.msl; then render-diff MSL_ref vs z.msl on Metal via ShaderCompare.
# MATCH = zioshade's GLSL renders identically to the reference = render-correct.
# Catches GLSL emission bugs (e.g. a phi resolving the wrong value) that the
# compile-only glslang gate cannot -- the silent-wrong discriminator for the
# GLSL backend's delicate phi/loop lowering.
#
# Usage: tools/glsl_render_check_spv.sh [corpus-dir]   (default: tests/cts/graphicsfuzz)
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_glsl_render_spv}
mkdir -p "$SHARE"
SC=$SHARE/ShaderCompare
[ -x "$SC" ] || swiftc -O tools/ShaderCompare.swift -o "$SC" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH"; exit 2; }
command -v spirv-dis >/dev/null || { echo "error: spirv-dis not on PATH (stage detection)"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }

glslang_stage() {
  case "$(spirv-dis "$1" 2>/dev/null | grep -m1 'OpEntryPoint' | awk '{print $2}')" in
    Fragment) echo "frag";; Vertex) echo "vert";; GLCompute) echo "comp";;
    Geometry) echo "geom";; TessellationControl) echo "tesc";; TessellationEvaluation) echo "tese";; *) echo "";;
  esac
}

check_one() {
  local spv="$1" name gs d
  name=$(basename "$spv" .spv)
  gs=$(glslang_stage "$spv"); [ -z "$gs" ] && { echo "skip-stage"; return; }
  d="$SHARE/$name"
  spirv-cross --msl "$spv" > "$d.ref.msl" 2>/dev/null || { echo "skip-crossmsl"; return; }
  "$CLI" glsl "$spv" > "$d.z.glsl" 2>/dev/null || { echo "skip-zglsl"; return; }
  glslangValidator -V -S "$gs" "$d.z.glsl" -o "$d.z.spv" >/dev/null 2>&1 || { echo "skip-zglslang"; return; }
  spirv-cross --msl "$d.z.spv" > "$d.z.msl" 2>/dev/null || { echo "skip-zcrossmsl"; return; }
  local o; o=$("$SC" "$d.z.msl" "$d.ref.msl" "${d}_r" 2>&1)
  printf '%s' "$o" | grep -q '^MATCH' && { echo "MATCH"; return; }
  printf '%s' "$o" | grep -q 'SKIP(harness-binding)' && { echo "skip-binding"; return; }
  printf '%s' "$o" | grep -qE '^DIFFER' || { echo "skip-render"; return; }
  local md; md=$(printf '%s' "$o" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$SC" "$d.z.msl" "$d.ref.msl" "${d}_rp" 2>&1)
  if printf '%s' "$os" | grep -q '^MATCH'; then echo "EDGE(fast-math-fp)"; else echo "DIFFER maxdiff=${md:-?}"; fi
}

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }
DIR=${1:-tests/cts/graphicsfuzz}
shopt -s nullglob
for f in "$DIR"/*.spv; do
  v=$(check_one "$f"); key=${v%% *}; bump "$key"
  case "$v" in DIFFER*) echo "$(basename "$f" .spv).spv: $v";; esac
done
echo ""
echo "=== GLSL render proxy (.spv) coverage: $DIR ==="
for k in MATCH "EDGE(fast-math-fp)" DIFFER skip-binding skip-stage skip-crossmsl skip-zglsl skip-zglslang skip-zcrossmsl skip-render; do
  echo "  $k: ${C[$k]:-0}"
done
