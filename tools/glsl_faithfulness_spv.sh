#!/usr/bin/env bash
# GLSL faithfulness check for BINARY SPIR-V (.spv) -- the .spv counterpart of
# tools/glsl_faithfulness.sh. The INDEPENDENT-ORACLE complement to the N=2
# render proxy (tools/glsl_render_check_spv.sh): isolates a REAL zioshade-GLSL
# bug from a spirv-cross/glslang proxy artifact by comparing, with NO spirv-cross
# on the critical path,
#   ref     = zioshade-MSL(source.spv)     -- the 3-oracle-proven render of the source
#   n.metal = naga(z.spv)                  -- an INDEPENDENT renderer of the round-tripped SPIR-V
# where z.spv = zioshade-GLSL(source.spv) -> glslang. MATCH (FAITHFUL) = zioshade-GLSL's
# round-tripped SPIR-V is semantically equivalent to source; DIFFER (UNFAITHFUL) = a real
# silent-wrong zioshade-GLSL bug.
#
# !!! EXPERIMENTAL -- LOW COVERAGE -- NOT STATISTICAL EVIDENCE OF CORRECTNESS !!!
# On tests/cts/graphicsfuzz this adjudicates only ~4/88 (4.5%). A 50% real-bug rate would
# pass UNDETECTED ~94% of the time at N=4. Three compounding ceilings:
#   1. NagaCompare binds NO textures/uniforms and is fragment-only -> ~43 skip-render (the
#      DOMINANT cap, NOT naga) + non-frag stages skip-stage. Lifting this needs a renderer
#      that binds resources (wgpu); out of scope here.
#   2. naga's SPIR-V frontend rejects image/sampler constructs (OpTypeSampledImage loads with
#      Unknown format) that spirv-val --target-env vulkan1.2 AND spirv-cross accept -> ~16
#      skip-naga. PROOF it is naga, not zioshade: naga rejects the UNTOUCHED source.spv
#      identically on every such case (zero z-only rejections observed). This class CANNOT
#      mask a zioshade-GLSL semantic bug -- a real bug lowers to valid SPIR-V naga reads fine
#      and renders to DIFFERENT pixels (UNFAITHFUL), never skip-naga. (One rejection was naga's
#      MSL BACKEND refusing `reverse_bits`, not its reader.)
#   3. zioshade's own gaps: skip-zglsl (honest refuse) + skip-zglslang (LOUD compile-failures
#      -- real GLSL-emission defects of a DIFFERENT class: undeclared id / redefinition /
#      missing entry point; the phi class. NOT silent-wrong; surfaced separately below.)
# "0 UNFAITHFUL" means no SILENT-WRONG bug in the trivial adjudicated subset, NOTHING broader.
# The real successor that lifts ceilings 1+2 at once is a Tint (spv->wgsl->wgpu) arm.
#
# Crash-classified: a zioshade-stage CRASH (CRASH-zglsl/CRASH-refmsl) is a mandate violation
# and fails the run (exit 1). glslang/naga crashes (CRASH-zglslang/CRASH-naga) are oracle
# messiness, reported but NOT fatal (zioshade is blameless for its oracles' stability).
#
# Usage: tools/glsl_faithfulness_spv.sh [corpus-dir|spv...]  (default: tests/cts/graphicsfuzz)
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_glsl_faith_spv}
mkdir -p "$SHARE"
NC=$SHARE/NagaCompare
[ -x "$NC" ] || swiftc -O tools/NagaCompare.swift -o "$NC" 2>/dev/null || { echo "error: swiftc (NagaCompare) failed"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v naga >/dev/null || { echo "error: naga not on PATH"; exit 2; }
command -v spirv-dis >/dev/null || { echo "error: spirv-dis not on PATH (stage detection)"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }

# rc>128 (signal) OR a panic signature in stderr. NOTE: callers MUST capture rc in a
# variable BEFORE the surrounding `if !`/pipeline clobbers $? (rc>128 is dead otherwise).
is_crash() {
  local errfile=$1 rc=$2
  [ "$rc" -gt 128 ] && return 0
  grep -qiE 'thread .main. panicked|reached unreachable|abort trap|trace/breakpoint trap|segmentation fault|sigsegv|sigabrt' "$errfile" 2>/dev/null && return 0
  return 1
}
glslang_stage() {
  case "$(spirv-dis "$1" 2>/dev/null | grep -m1 'OpEntryPoint' | awk '{print $2}')" in
    Fragment) echo "frag";; Vertex) echo "vert";; GLCompute) echo "comp";;
    Geometry) echo "geom";; TessellationControl) echo "tesc";; TessellationEvaluation) echo "tese";; *) echo "";;
  esac
}

ANY_ZS_CRASH=0   # zioshade-owned stage crashed -> mandate violation -> exit 1
check_one() {
  local spv="$1" name gs d rc
  name=$(basename "$spv" .spv)
  gs=$(glslang_stage "$spv")
  [ -z "$gs" ] && { echo "skip-stage"; return; }
  [ "$gs" != "frag" ] && { echo "skip-stage"; return; }  # NagaCompare is fragment-only
  d="$SHARE/$name"

  "$CLI" glsl "$spv" > "$d.z.glsl" 2>"$d.zglsl.err"; rc=$?
  if [ $rc -ne 0 ]; then
    if is_crash "$d.zglsl.err" "$rc"; then ANY_ZS_CRASH=1; echo "CRASH-zglsl"; else echo "skip-zglsl"; fi; return
  fi
  glslangValidator -V -S frag "$d.z.glsl" -o "$d.z.spv" >"$d.zg.err" 2>&1; rc=$?
  if [ $rc -ne 0 ]; then
    # glslang is an ORACLE; its crash is not a zioshade mandate violation.
    if is_crash "$d.zg.err" "$rc"; then echo "CRASH-zglslang"; else echo "skip-zglslang"; fi; return
  fi
  "$CLI" msl "$spv" > "$d.ref.msl" 2>"$d.refmsl.err"; rc=$?
  if [ $rc -ne 0 ]; then
    if is_crash "$d.refmsl.err" "$rc"; then ANY_ZS_CRASH=1; echo "CRASH-refmsl"; else echo "skip-refmsl"; fi; return
  fi
  naga "$d.z.spv" "$d.z.naga.metal" >"$d.naga.err" 2>&1; rc=$?
  if [ $rc -ne 0 ]; then
    # naga is an ORACLE; its crash/reject is not a zioshade mandate violation.
    if is_crash "$d.naga.err" "$rc"; then echo "CRASH-naga"; else echo "skip-naga"; fi; return
  fi
  local o; o=$("$NC" "$d.ref.msl" "$d.z.naga.metal" "${d}_r" 2>&1)
  printf '%s' "$o" | grep -q '^MATCH' && { echo "FAITHFUL"; return; }
  printf '%s' "$o" | grep -q '^DIFFER' || { echo "skip-render"; return; }
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$NC" "$d.ref.msl" "$d.z.naga.metal" "${d}_rp" 2>&1)
  if printf '%s' "$os" | grep -q '^MATCH'; then echo "FAITHFUL(edge)"; else echo "UNFAITHFUL"; fi
}

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }   # bump the FULL verdict string (no ${v%% *} truncation)
DIR=""
for a in "$@"; do if [ -d "$a" ]; then DIR="$a"; else break; fi; done
DIR=${DIR:-tests/cts/graphicsfuzz}
shopt -s nullglob
if [ $# -ge 1 ] && [ -f "$1" ]; then files=("$@"); else files=("$DIR"/*.spv); fi
for f in "${files[@]}"; do
  v=$(check_one "$f"); bump "$v"
  case "$v" in UNFAITHFUL|CRASH-*) echo "$(basename "$f" .spv).spv: $v";; esac
done
echo ""
echo "=== GLSL faithfulness (.spv): zioshade-MSL(source) vs naga(zioshade-GLSL->spv) ==="
echo "  (EXPERIMENTAL: ~4/88 adjudicated; NOT statistical evidence of correctness.)"
for k in FAITHFUL "FAITHFUL(edge)" UNFAITHFUL skip-stage skip-zglsl skip-zglslang skip-refmsl skip-naga skip-render \
         CRASH-zglsl CRASH-refmsl CRASH-zglslang CRASH-naga; do
  echo "  $k: ${C[$k]:-0}"
done
echo "  NOTE: skip-zglslang are LOUD zioshade-GLSL compile-failures (real defects of a"
echo "        DIFFERENT class -- undeclared id / redefinition / missing entry; NOT silent-wrong)."
[ "$ANY_ZS_CRASH" -eq 0 ] || { echo "FAIL: a zioshade stage crashed (mandate violation)"; exit 1; }
