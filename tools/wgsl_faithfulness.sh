#!/usr/bin/env bash
# WGSL faithfulness check — non-proxy ground truth for zioshade-WGSL (mirror of
# glsl_faithfulness.sh). Renders naga(zioshade-WGSL(source)) [WGSL->MSL directly, no
# spirv-cross] vs zioshade-MSL(source) [the proven-correct reference]. MATCH => zioshade-WGSL
# is faithful. DIFFER => worth investigating.
#
# CAVEAT (frontend confound): unlike the GLSL check (glslang on BOTH sides — clean), the
# WGSL source goes through glslang and zioshade-WGSL goes through naga's WGSL frontend, so a
# DIFFER can also be a naga-wgsl-vs-glslang frontend difference, not a zioshade-WGSL bug.
# Verify any UNFAITHFUL result directly (does zioshade-WGSL's output actually drop/misemit
# control flow?) before calling it a bug. A direct wgpu render is the only fully-clean check.
#
# Usage: tools/wgsl_faithfulness.sh <frag>...
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_wgsl_faith}
mkdir -p "$SHARE"
NC=$SHARE/NagaCompare
[ -x "$NC" ] || swiftc -O tools/NagaCompare.swift -o "$NC" 2>/dev/null || { echo "error: swiftc (NagaCompare) failed"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v naga >/dev/null || { echo "error: naga not on PATH"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }

check_one() {
  local frag="$1" name; name=$(basename "$frag" .frag)
  local d="$SHARE/$name"
  sed 's/^\(out [a-z0-9]*vec4 [A-Za-z_][A-Za-z0-9_]*;\)/layout(location=0) \1/' "$frag" > "$d.g.frag"
  glslangValidator -V -S frag "$d.g.frag" -o "$d.src.spv" >/dev/null 2>&1 || { echo "skip-glslang"; return; }
  "$CLI" wgsl "$d.src.spv" --stage fragment > "$d.z.wgsl" 2>/dev/null || { echo "skip-zwgsl"; return; }
  # naga renders zioshade-WGSL directly to MSL (no spirv-cross round-trip)
  naga --input-kind wgsl "$d.z.wgsl" "$d.z.metal" >/dev/null 2>&1 || { echo "skip-naga"; return; }
  "$CLI" msl "$d.src.spv" --stage fragment > "$d.ref.msl" 2>/dev/null || { echo "skip-refmsl"; return; }
  local o; o=$("$NC" "$d.ref.msl" "$d.z.metal" "${d}_r" 2>&1)
  printf '%s' "$o" | grep -q 'MATCH' && { echo "FAITHFUL"; return; }
  printf '%s' "$o" | grep -q 'DIFFER' || { echo "skip-render"; return; }
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$NC" "$d.ref.msl" "$d.z.metal" "${d}_rp" 2>&1)
  if printf '%s' "$os" | grep -q 'MATCH'; then echo "FAITHFUL(edge)"; else echo "UNFAITHFUL(real WGSL bug)"; fi
}

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }

[ $# -ge 1 ] || { echo "Usage: tools/wgsl_faithfulness.sh <frag>..."; exit 1; }
for f in "$@"; do
  [ -e "$f" ] || { echo "$(basename "$f"): not found"; continue; }
  v=$(check_one "$f"); bump "$v"; echo "$(basename "$f" .frag).frag: $v"
done

echo ""
echo "=== WGSL faithfulness (naga on zioshade-WGSL vs zioshade-MSL source) ==="
for k in FAITHFUL "FAITHFUL(edge)" "UNFAITHFUL(real WGSL bug)" skip-glslang skip-zwgsl skip-naga skip-refmsl skip-render; do
  echo "  $k: ${C[$k]:-0}"
done
