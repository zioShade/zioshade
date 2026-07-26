#!/usr/bin/env bash
# naga 2nd-oracle MSL render-diff: closes the correlated-error blind spot.
#
# A single-oracle (SPIRV-Cross) render differential cannot see a spec misreading that
# both zioshade and SPIRV-Cross share — both render identically-but-WRONG and pass.
# naga is an INDEPENDENT cross-compiler with an MSL backend; this script render-diffs
# zioshade-MSL vs naga-MSL on Metal over the SAME surface prove.sh covers (UNOPTIMIZED
# glslang SPIR-V). Where both agree pixel-for-pixel, the shader is render-proven-2-oracle
# — the correlated-error blind spot is closed for it.
#
# HARD RULE (per the deciding panel): a DIFFER here has NO ground truth (naga may be the
# outlier, or all three differ). It is FLAGGED for investigation, NEVER auto-"fixed" —
# manufacturing a fix would be the plausible-wrong-chasing the project exists to prevent.
#
# NagaCompare.swift (first cut) handles the simple main_1(float4& pos, float4& color)
# signature; richer signatures honest-skip as skip-naga-complex. Coverage grows as
# NagaCompare learns more signatures.
#
# Usage: tools/prove_naga.sh --sweep [--every N] | --dir <path>
#   --sweep         corpus (tests/spirv-cross/*.frag); --every N = every Nth (default 25)
#   --dir <path>    sweep a directory's *.frag (full, no sampling)
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_prove_naga}
mkdir -p "$SHARE"
NC=$SHARE/NagaCompare
[ -x "$NC" ] || swiftc -O tools/NagaCompare.swift -o "$NC" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }
command -v naga >/dev/null || { echo "error: naga not on PATH"; exit 2; }

check_one() {
  local frag="$1" name; name=$(basename "$frag" .frag)
  local spv="$SHARE/$name.spv" nm="$SHARE/$name.naga.metal" zm="$SHARE/$name.z.msl"
  # glslang needs an explicit output location on a bare `out vecN name;`.
  sed 's/^\(out [a-z0-9]*vec4 [A-Za-z_][A-Za-z0-9_]*;\)/layout(location=0) \1/' "$frag" > "$SHARE/$name.g.frag"
  glslangValidator -V -S frag "$SHARE/$name.g.frag" -o "$spv" >/dev/null 2>&1 || { echo "skip-glslang"; return; }
  naga "$spv" "$nm" 2>/dev/null || { echo "skip-naga"; return; }
  "$CLI" msl "$spv" --stage fragment > "$zm" 2>/dev/null || { echo "skip-zioshade-msl"; return; }
  # Render naga's native `main_` entry; shaders needing buffer/texture bindings skip-render.
  local o rc; o=$("$NC" "$zm" "$nm" "$SHARE/${name}_n" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && { echo "skip-render"; return; }
  printf '%s' "$o" | grep -q 'MATCH' && { echo "MATCH"; return; }
  printf '%s' "$o" | grep -q 'DIFFER' || { echo "skip-render"; return; }
  # Triage the DIFFER: re-render with precise FP. MATCH => benign FP-contraction at a
  # boundary (EDGE). Still DIFFER => persists precise-FP — but that does NOT mean a bug:
  # it also covers chaotic whole-image FP divergence (two correct compilers emit different
  # FP orderings for a fractal's escape iteration, amplified to total disagreement, e.g.
  # mandelbox). So label it "persistent" (flagged, spans benign-chaotic to control-flow),
  # never "structural" (which would over-claim). No ground truth → never auto-fixed.
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$NC" "$zm" "$nm" "$SHARE/${name}_ns" 2>&1)
  if printf '%s' "$os" | grep -q 'MATCH'; then echo "EDGE(naga-fp)"; else echo "DIFFER(naga-persistent,FLAG)"; fi
}

# Tally counters
declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }

run_one() { local f="$1" v; v=$(check_one "$f"); bump "$v"; echo "$(basename "$f" .frag).frag: $v"; }

if [ "${1:-}" = "--dir" ]; then
  for f in "${2:?usage: --dir <path>}"/*.frag; do
    [ -e "$f" ] || continue; case "$f" in *.asm.*) continue;; esac
    run_one "$f"
  done
elif [ "${1:-}" = "--sweep" ]; then
  every=${EVERY:-25}; i=0
  for f in tests/spirv-cross/*.frag; do
    case "$f" in *.asm.*) continue;; esac
    i=$((i+1)); [ $(( i % every )) -eq 0 ] && run_one "$f"
  done
else
  echo "Usage: tools/prove_naga.sh --sweep [--every N] | --dir <path>"
  echo "  naga 2nd-oracle MSL render-diff (zioshade msl vs naga .metal), unoptimized SPIR-V."
  exit 1
fi

echo ""
echo "=== naga 2nd-oracle coverage ==="
for k in MATCH "EDGE(naga-fp)" "DIFFER(naga-persistent,FLAG)" skip-glslang skip-naga skip-zioshade-msl skip-render; do
  echo "  $k: ${C[$k]:-0}"
done
