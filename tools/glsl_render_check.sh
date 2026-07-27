#!/usr/bin/env bash
# GLSL render proxy — render-verify zioshade's GLSL output on Metal (no OpenGL needed).
#
# zioshade's GLSL output is round-tripped: zioshade GLSL ->(glslang -V)-> SPIR-V
# ->(spirv-cross --msl)-> MSL, then render-diffed on Metal vs MSL_ref (spirv-cross --msl
# of the SOURCE SPIR-V, the render-proven path). MATCH = zioshade's GLSL output renders
# identically to the reference = GLSL render-correct (as glslang parses it). Catches GLSL
# emission bugs that the compile-only glslang gate misses.
#
# Same caveat as the HLSL render proxy (hlsl_render_check.sh): a DIFFER has no ground
# truth on chaotic shaders (benign FP ordering divergence) — flagged, never auto-fixed.
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_glsl_render}
mkdir -p "$SHARE"
SC=$SHARE/ShaderCompare
[ -x "$SC" ] || swiftc -O tools/ShaderCompare.swift -o "$SC" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }

check_one() {
  local frag="$1" name; name=$(basename "$frag" .frag)
  local d="$SHARE/$name"
  sed 's/^\(out [a-z0-9]*vec4 [A-Za-z_][A-Za-z0-9_]*;\)/layout(location=0) \1/' "$frag" > "$d.g.frag"
  glslangValidator -V -S frag "$d.g.frag" -o "$d.src.spv" >/dev/null 2>&1 || { echo "skip-glslang"; return; }
  spirv-cross --msl "$d.src.spv" > "$d.ref.msl" 2>/dev/null || { echo "skip-crossmsl"; return; }
  "$CLI" glsl "$d.src.spv" --stage fragment > "$d.z.glsl" 2>/dev/null || { echo "skip-zglsl"; return; }
  glslangValidator -V -S frag "$d.z.glsl" -o "$d.z.spv" >/dev/null 2>&1 || { echo "skip-zglslang"; return; }
  spirv-cross --msl "$d.z.spv" > "$d.z.msl" 2>/dev/null || { echo "skip-zcrossmsl"; return; }
  local o; o=$("$SC" "$d.z.msl" "$d.ref.msl" "${d}_r" 2>&1)
  printf '%s' "$o" | grep -q '^MATCH' && { echo "MATCH"; return; }
  printf '%s' "$o" | grep -qE '^DIFFER' || { echo "skip-render"; return; }
  local md; md=$(printf '%s' "$o" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
  echo "DIFFER maxdiff=${md:-?}"
}

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }
DIR=${1:-tests/spirv-cross}
for f in "$DIR"/*.frag; do
  case "$f" in *.asm.*) continue;; esac
  [ -e "$f" ] || continue
  v=$(check_one "$f"); key=${v%% *}; bump "$key"
  case "$v" in DIFFER*) echo "$(basename "$f" .frag).frag: $v";; esac
done
echo ""
echo "=== GLSL render proxy coverage ==="
for k in MATCH DIFFER skip-glslang skip-crossmsl skip-zglsl skip-zglslang skip-zcrossmsl skip-render; do
  echo "  $k: ${C[$k]:-0}"
done
