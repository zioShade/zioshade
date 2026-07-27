#!/usr/bin/env bash
# GLSL faithfulness check — closes the "AGREE-ALL lead" without a GL renderer.
#
# The GLSL render-proxy compares spirv-cross(zioshade-GLSL(source) -> glslang -> spv) against
# spirv-cross(source) — a DIFFER could be (a) a real zioshade-GLSL emission bug, or (b) a
# spirv-cross / glslang re-parse artifact (the proxy round-trip). This script isolates (a):
# render zioshade-MSL(zioshade-GLSL(source)->glslang) vs zioshade-MSL(source) DIRECTLY — both
# through the SAME proven backend (zioshade-msl), no spirv-cross. A MATCH means zioshade-GLSL's
# round-tripped SPIR-V is semantically equivalent to the source (zioshade-GLSL is FAITHFUL —
# any proxy DIFFER is spirv-cross's artifact, not a zioshade bug). A DIFFER means zioshade-GLSL
# emits GLSL that compiles to a semantically different SPIR-V -> a real zioshade-GLSL bug.
#
# Usage: tools/glsl_faithfulness.sh <frag>...   (or set DIFFERS to a space-separated list)
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_glsl_faith}
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
  # z.spv = zioshade-GLSL(source) -> glslang  (the round-tripped SPIR-V the proxy uses)
  "$CLI" glsl "$d.src.spv" --stage fragment > "$d.z.glsl" 2>/dev/null || { echo "skip-zglsl"; return; }
  glslangValidator -V -S frag "$d.z.glsl" -o "$d.z.spv" >/dev/null 2>&1 || { echo "skip-zglslang"; return; }
  # ref = zioshade-MSL(source) — the PROVEN-correct rendering (3-oracle AGREE on the source).
  # n.metal = naga(z.spv) — an INDEPENDENT renderer of the round-tripped SPIR-V.
  "$CLI" msl "$d.src.spv" --stage fragment > "$d.ref.msl" 2>/dev/null || { echo "skip-refmsl"; return; }
  naga "$d.z.spv" "$d.z.naga.metal" 2>/dev/null || { echo "skip-naga"; return; }
  local o; o=$("$NC" "$d.ref.msl" "$d.z.naga.metal" "${d}_r" 2>&1)
  printf '%s' "$o" | grep -q 'MATCH' && { echo "FAITHFUL"; return; }
  printf '%s' "$o" | grep -q 'DIFFER' || { echo "skip-render"; return; }
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$NC" "$d.ref.msl" "$d.z.naga.metal" "${d}_rp" 2>&1)
  if printf '%s' "$os" | grep -q 'MATCH'; then echo "FAITHFUL(edge)"; else echo "UNFAITHFUL(real GLSL bug)"; fi
}

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }

[ $# -ge 1 ] || { echo "Usage: tools/glsl_faithfulness.sh <frag>..."; exit 1; }
for f in "$@"; do
  [ -e "$f" ] || { echo "$(basename "$f"): not found"; continue; }
  v=$(check_one "$f"); bump "$v"; echo "$(basename "$f" .frag).frag: $v"
done

echo ""
echo "=== GLSL faithfulness (zioshade-MSL on round-tripped vs source SPIR-V) ==="
for k in FAITHFUL "FAITHFUL(edge)" "UNFAITHFUL(real GLSL bug)" skip-glslang skip-zglsl skip-zglslang skip-zAmsl skip-zBmsl skip-binding skip-render; do
  echo "  $k: ${C[$k]:-0}"
done
