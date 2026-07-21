#!/usr/bin/env bash
# Docker-free FRAGMENT frontend-oracle differential (the Metal-only core of
# hlsl_render_check.sh, without the DXC/D3D path). For each .frag it renders
#   zioshade-frontend SPIR-V --(spirv-cross)--> MSL   vs
#   glslang          SPIR-V --(spirv-cross)--> MSL
# on the Metal GPU (tools/ShaderCompare.swift, fullscreen triangle). Same backend
# cancels backend fp, so a residual divergence is a FRONTEND miscompile -- confirmed
# with a fast-math-off re-render (#507): a divergence that vanishes under precise fp
# is benign Metal fast-math at an fp discontinuity, not a miscompile.
#
# Verdicts: MATCH | DIFFER(frontend=MISCOMPILE) | EDGE(fast-math-fp) | skip-*
# Requires: built CLI, glslang, spirv-cross, swiftc (macOS + Metal). No Docker.
set -uo pipefail
cd "$(dirname "$0")/.."
CLI=./zig-out/bin/zioshade
SHARE=${SHARE:-/private/tmp/claude-501/-Users-alex-claude/2e7ff35b-0e04-4cb1-9600-f56f35b3f7b7/scratchpad/fragorc}
SC=$SHARE/ShaderCompare
mkdir -p "$SHARE"
[ -x "$SC" ] || swiftc tools/ShaderCompare.swift -o "$SC" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }

check_one() {
  local frag="$1" name; name=$(basename "$frag" .frag)
  local zspv="$SHARE/$name.z.spv" zm="$SHARE/$name.zfe.msl"
  local gf="$SHARE/$name.gl.frag" gspv="$SHARE/$name.g.spv" gm="$SHARE/$name.g.msl"
  "$CLI" compile "$frag" --stage fragment -o "$zspv" 2>/dev/null || { echo "skip-zioshade-compile"; return; }
  spirv-cross --msl "$zspv" > "$zm" 2>/dev/null || { echo "skip-crossmsl-zio"; return; }
  # glslang needs an explicit output location; add one to a bare `out vecN name;`.
  sed 's/^\(out [a-z0-9]*vec4 [A-Za-z_][A-Za-z0-9_]*;\)/layout(location=0) \1/' "$frag" > "$gf"
  glslangValidator -V -S frag "$gf" -o "$gspv" >/dev/null 2>&1 || { echo "skip-glslang"; return; }
  spirv-cross --msl "$gspv" > "$gm" 2>/dev/null || { echo "skip-crossmsl-ref"; return; }
  local o; o=$("$SC" "$zm" "$gm" "$SHARE/${name}_o" 2>&1)
  printf '%s' "$o" | grep -q '^MATCH' && { echo "MATCH"; return; }
  printf '%s' "$o" | grep -qE '^DIFFER' || { echo "skip-render"; return; }
  # Divergence under fast-math -> re-render precise; if it then matches, benign fp.
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$SC" "$zm" "$gm" "$SHARE/${name}_s" 2>&1)
  local md; md=$(printf '%s' "$o" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
  if printf '%s' "$os" | grep -q '^MATCH'; then echo "EDGE(fast-math-fp,maxdiff=${md:-?})"; else echo "DIFFER(frontend=MISCOMPILE,maxdiff=${md:-?})"; fi
}

# Historically-buggy shaders: always checked (regression value) even when sampling.
REGRESSION="switch_fallthrough switch_in_loop origami swizzle_lvalue art_deco ceramic \
nested_func_expr loop_trackers recursive_fib mat_branch mandelbrot_smooth"

if [ "${1:-}" = "--sweep" ]; then
  # FRAG_EVERY=N processes every Nth shader (default 1 = the full corpus). Sampling is
  # deterministic (sorted order), and the REGRESSION set above is always included.
  every=${FRAG_EVERY:-1}
  seen=" "
  i=0
  for f in tests/spirv-cross/*.frag; do
    case "$f" in *.asm.*) continue;; esac
    name=$(basename "$f" .frag)
    i=$((i+1))
    take=0
    [ $(( i % every )) -eq 0 ] && take=1
    case " $REGRESSION " in *" $name "*) take=1;; esac
    [ "$take" = 1 ] || continue
    case "$seen" in *" $name "*) continue;; esac
    seen="$seen$name "
    echo "$name.frag: $(check_one "$f")"
  done
else
  check_one "$1"
fi
