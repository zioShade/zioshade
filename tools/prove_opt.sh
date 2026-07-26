#!/usr/bin/env bash
# Optimized-SPIR-V MSL BACKEND render-diff: the spirv-opt -O semantic surface.
#
# The existing frag_oracle_check.sh render-diff tests the GLSL→SPIR-V FRONTEND
# (both sides lowered by spirv-cross, so "same backend cancels backend fp" — a
# residual divergence is a FRONTEND miscompile). It never invokes zioshade's own
# spirv_to_msl.zig backend, and it uses UNOPTIMIZED glslang SPIR-V.
#
# This script is the complement: it feeds spirv-opt -O SPIR-V into zioshade's OWN
# MSL backend (`zioshade msl <opt.spv>`) and spirv-cross's MSL backend, then
# render-diffs them on Metal. A divergence here is a BACKEND miscompile on
# OPTIMIZED SPIR-V — the surface where the phi/merge (#477/#478), load-cache
# (#235/#223), and type-dedup (#188/#173) plausible-wrong classes live. These are
# unreachable by the unoptimized frontend render-diff (prove.sh) and the
# compile-only gates.
#
# IMPORTANT — this is a BACKEND differential (zioshade-msl vs spirv-cross-msl),
# NOT "same backend cancels." So a divergence could be a real miscompile OR a
# benign backend difference (e.g. fast-math-fp). Each DIFFER is re-rendered with
# precise math (SHADERCOMPARE_SAFE_MATH=1); if it then matches, it's a benign
# EDGE. A persistent DIFFER(backend=MISCOMPILE) is the actionable signal.
#
# Usage: tools/prove_opt.sh [--sweep [--every N]] [--dir <path>]
#   --sweep         corpus (tests/spirv-cross/*.frag); --every N = every Nth (default 25)
#   --dir <path>    sweep a directory's *.frag (full, no sampling)
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_prove_opt}
mkdir -p "$SHARE"
SC=$SHARE/ShaderCompare
[ -x "$SC" ] || swiftc -O tools/ShaderCompare.swift -o "$SC" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }
command -v spirv-opt >/dev/null || { echo "error: spirv-opt not on PATH"; exit 2; }

check_one() {
  local frag="$1" name; name=$(basename "$frag" .frag)
  local optspv="$SHARE/$name.opt.spv" zm="$SHARE/$name.zb.msl" gm="$SHARE/$name.g.msl"
  # glslang needs an explicit output location on a bare `out vecN name;`.
  sed 's/^\(out [a-z0-9]*vec4 [A-Za-z_][A-Za-z0-9_]*;\)/layout(location=0) \1/' "$frag" > "$SHARE/$name.g.frag"
  glslangValidator -V -S frag "$SHARE/$name.g.frag" -o "$SHARE/$name.g.spv" >/dev/null 2>&1 || { echo "skip-glslang"; return; }
  spirv-opt -O "$SHARE/$name.g.spv" -o "$optspv" 2>/dev/null || { echo "skip-opt"; return; }
  # zioshade's OWN MSL backend on the optimized SPIR-V.
  "$CLI" msl "$optspv" --stage fragment > "$zm" 2>/dev/null || { echo "skip-zioshade-msl"; return; }
  # spirv-cross MSL reference on the SAME optimized SPIR-V.
  spirv-cross --msl "$optspv" > "$gm" 2>/dev/null || { echo "skip-crossmsl"; return; }
  local o; o=$("$SC" "$zm" "$gm" "$SHARE/${name}_o" 2>&1)
  printf '%s' "$o" | grep -q '^MATCH' && { echo "MATCH"; return; }
  printf '%s' "$o" | grep -qE '^DIFFER' || { echo "skip-render"; return; }
  # Re-render precise; if it matches, benign fast-math-fp.
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$SC" "$zm" "$gm" "$SHARE/${name}_s" 2>&1)
  local md; md=$(printf '%s' "$o" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
  if printf '%s' "$os" | grep -q '^MATCH'; then echo "EDGE(fast-math-fp,maxdiff=${md:-?})"; else echo "DIFFER(backend=MISCOMPILE,maxdiff=${md:-?})"; fi
}

if [ "${1:-}" = "--dir" ]; then
  for f in "${2:?usage: --dir <path>}"/*.frag; do
    [ -e "$f" ] || continue
    case "$f" in *.asm.*) continue;; esac
    echo "$(basename "$f" .frag).frag: $(check_one "$f")"
  done
elif [ "${1:-}" = "--sweep" ]; then
  every=${EVERY:-25}
  i=0
  for f in tests/spirv-cross/*.frag; do
    case "$f" in *.asm.*) continue;; esac
    i=$((i+1))
    [ $(( i % every )) -eq 0 ] && echo "$(basename "$f" .frag).frag: $(check_one "$f")"
  done
else
  echo "Usage: tools/prove_opt.sh --sweep [--every N] | --dir <path>"
  echo "  Optimized-SPIR-V (spirv-opt -O) MSL backend render-diff (zioshade msl vs spirv-cross --msl)."
  exit 1
fi
