#!/usr/bin/env bash
# WGSL render proxy — render-verify zioshade's WGSL output on Metal (no wgpu needed).
#
# zioshade's WGSL output is round-tripped: zioshade WGSL ->(naga --input-kind wgsl)->
# SPIR-V ->(spirv-cross --msl)-> MSL, then render-diffed on Metal vs MSL_ref
# (spirv-cross --msl of the SOURCE SPIR-V). MATCH = zioshade's WGSL output renders
# identically to the reference = WGSL render-correct (as naga parses it). Catches WGSL
# emission bugs that the compile-only naga gate (wgsl_naga_sweep) misses.
#
# Same caveat as the GLSL/HLSL render proxies: a DIFFER on a chaotic shader is benign FP
# ordering divergence (no ground truth) — flagged, never auto-fixed.
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_wgsl_render}
mkdir -p "$SHARE"
SC=$SHARE/ShaderCompare
[ -x "$SC" ] || swiftc -O tools/ShaderCompare.swift -o "$SC" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }
command -v naga >/dev/null || { echo "error: naga not on PATH"; exit 2; }
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }

check_one() {
  local frag="$1" name; name=$(basename "$frag" .frag)
  local d="$SHARE/$name"
  sed 's/^\(out [a-z0-9]*vec4 [A-Za-z_][A-Za-z0-9_]*;\)/layout(location=0) \1/' "$frag" > "$d.g.frag"
  glslangValidator -V -S frag "$d.g.frag" -o "$d.src.spv" >/dev/null 2>&1 || { echo "skip-glslang"; return; }
  spirv-cross --msl "$d.src.spv" > "$d.ref.msl" 2>/dev/null || { echo "skip-crossmsl"; return; }
  "$CLI" wgsl "$d.src.spv" --stage fragment > "$d.z.wgsl" 2>/dev/null || { echo "skip-zwgsl"; return; }
  naga --input-kind wgsl "$d.z.wgsl" "$d.z.spv" >/dev/null 2>&1 || { echo "skip-naga"; return; }
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
echo "=== WGSL render proxy coverage ==="
for k in MATCH DIFFER skip-glslang skip-crossmsl skip-zwgsl skip-naga skip-zcrossmsl skip-render; do
  echo "  $k: ${C[$k]:-0}"
done
