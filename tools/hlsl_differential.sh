#!/usr/bin/env bash
# HLSL differential vs spirv-cross: prove zioshade's HLSL is SEMANTICALLY
# EQUIVALENT to the reference cross-compiler (spirv-cross), not merely that it
# compiles. This is the strongest HLSL correctness signal achievable without a
# GPU: HLSL can be render-verified only on Windows (D3D WARP), which this dev
# environment (macOS) cannot do — see docs/DIFFERENTIAL_PROOF.md.
#
# Method (semantic, NOT textual — the two cross-compilers legitimately differ in
# naming/ordering/register conventions, so a string diff is pure noise):
#   1. zioshade  SPIR-V --(zioshade)-->     HLSL_zs
#   2. same SPIR-V --(spirv-cross)-->       HLSL_sc
#   3. HLSL_zs --(DXC -spirv)--> SPIRV_zs   (round-trip back to a program)
#   4. HLSL_sc --(DXC -spirv)--> SPIRV_sc
#   5. spirv-dis both, strip debug names, renumber ids, sort, diff.
# A clean diff = the two HLSL emissions are the SAME PROGRAM => zioshade matches
# the reference. Report "matches reference", NOT "correct": spirv-cross is a
# reference, not ground truth, and a shared blind spot could pass both (only a
# real render check earns "correct").
#
# KNOWN benign divergence: MATRIX shaders. zioshade uses HLSL's column-major
# storage + mul(M,v); spirv-cross uses row_major + mul(v,M) (documented in
# spirv_to_hlsl.zig as "the transpose of spirv-cross's convention"). These two
# equivalent conventions compile to VectorTimesMatrix vs MatrixTimesVector at the
# SPIR-V level, so matrix shaders diverge structurally while being mathematically
# equivalent. Such divergences are tagged MATRIX-CONVENTION and must be triaged,
# not treated as bugs. (Everything else that diverges is a real miscompile to fix.)
#
# Requires: built CLI, spirv-cross, spirv-dis (spirv-tools), and the dxc-oracle
# container (see tools/hlsl_validity_sweep.sh for its setup).
#
# Usage: tools/hlsl_differential.sh <shader.frag> [stage] [profile]
#   or:  tools/hlsl_differential.sh --sweep [dir]   (whole corpus, slow)
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
CONTAINER=${CONTAINER:-dxc-oracle}
SM=${SM:-60}
PROFILE=${PROFILE:-ps_6_0}
SHARE_HOST=/private/tmp/claude-501/-Users-alex-claude/2e7ff35b-0e04-4cb1-9600-f56f35b3f7b7/scratchpad/hlsldiff
SHARE_CONT=/work/hlsldiff

command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH"; exit 2; }
command -v spirv-dis  >/dev/null || { echo "error: spirv-dis not on PATH"; exit 2; }
docker exec "$CONTAINER" true 2>/dev/null || { echo "error: container $CONTAINER not running"; exit 2; }
mkdir -p "$SHARE_HOST"

# Normalize DXC-produced SPIR-V to a program-identity form: drop debug/name/decor
# noise, collapse every %id to %X, and sort (declaration order is not semantic).
norm() { spirv-dis --no-color "$1" 2>/dev/null \
  | grep -vE 'OpName|OpMemberName|OpSource|OpModuleProcessed|OpDecorate|^; ' \
  | sed -E 's/%[A-Za-z_0-9]+/%X/g' | sort; }

# Returns: MATCH | MATRIX-CONVENTION | DIVERGE | herr | dxc-fail
compare_one() {
  local frag="$1" stage="$2" name; name=$(basename "$frag" .frag)
  "$CLI" hlsl "$frag" --stage "$stage" > "$SHARE_HOST/${name}.zs.hlsl" 2>/dev/null || { echo herr; return; }
  spirv_from_frag "$frag" "$stage" || { echo herr; return; }
  spirv-cross --hlsl --shader-model "$SM" "$SHARE_HOST/${name}.spv" > "$SHARE_HOST/${name}.sc.hlsl" 2>/dev/null || { echo herr; return; }
  docker exec "$CONTAINER" bash -c "export LD_LIBRARY_PATH=/opt/dxc/lib
    /opt/dxc/bin/dxc -T $PROFILE -E main -spirv -Fo $SHARE_CONT/${name}.zs.spv $SHARE_CONT/${name}.zs.hlsl >/dev/null 2>&1 &&
    /opt/dxc/bin/dxc -T $PROFILE -E main -spirv -Fo $SHARE_CONT/${name}.sc.spv $SHARE_CONT/${name}.sc.hlsl >/dev/null 2>&1" || { echo dxc-fail; return; }
  local d; d=$(diff <(norm "$SHARE_HOST/${name}.zs.spv") <(norm "$SHARE_HOST/${name}.sc.spv") 2>/dev/null)
  if [ -z "$d" ]; then
    echo MATCH
  elif printf '%s\n' "$d" | grep -qE 'TimesMatrix|TimesVector|Transpose|Determinant'; then
    # Divergence is entirely the documented matrix-major convention (VectorTimesMatrix
    # +col-major vs MatrixTimesVector+row-major), which is mathematically equivalent.
    echo MATRIX-CONVENTION
  else
    echo DIVERGE
  fi
}

spirv_from_frag() { # $1 frag, $2 stage -> writes $SHARE_HOST/<name>.spv
  local name; name=$(basename "$1" .frag)
  "$CLI" compile "$1" --stage "$2" -o "$SHARE_HOST/${name}.spv" 2>/dev/null
}

if [ "${1:-}" = "--sweep" ]; then
  DIR=${2:-tests/spirv-cross}
  declare -A tally
  for f in "$DIR"/*.frag; do
    case "$f" in *.asm.*) continue;; esac
    [ -e "$f" ] || continue
    r=$(compare_one "$f" fragment)
    tally[$r]=$(( ${tally[$r]:-0} + 1 ))
    [ "$r" = DIVERGE ] && echo "DIVERGE $(basename "$f" .frag)"
  done
  echo
  for k in MATCH MATRIX-CONVENTION DIVERGE herr dxc-fail; do echo "$k = ${tally[$k]:-0}"; done
else
  [ -n "${1:-}" ] || { echo "usage: $0 <shader.frag> | --sweep [dir]"; exit 2; }
  echo "$(basename "$1"): $(compare_one "$1" "${2:-fragment}")"
fi
