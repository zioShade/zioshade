#!/usr/bin/env bash
# GLSL faithfulness check for BINARY SPIR-V (.spv) -- the .spv counterpart of
# tools/glsl_faithfulness.sh (which starts from .frag). The INDEPENDENT-ORACLE
# complement to tools/glsl_render_check_spv.sh: isolates a REAL zioshade-GLSL bug
# from a spirv-cross/glslang proxy-round-trip artifact.
#
# The render proxy (N=2, both arms through spirv-cross --msl) measures
# agreement-with-spirv-cross, not correctness -- a shared spirv-cross bug yields
# a false MATCH, and a DIFFER is ambiguous (real zioshade bug vs spirv-cross
# artifact). This script breaks that correlation: it compares
#   ref  = zioshade-MSL(source.spv)         -- the PROVEN-correct render (3-oracle AGREE on source)
#   n.metal = naga(z.spv)                    -- an INDEPENDENT renderer of the round-tripped SPIR-V
# where z.spv = zioshade-GLSL(source.spv) -> glslang. Both ref and n.metal are
# independent of spirv-cross. MATCH(FAITHFUL) = zioshade-GLSL's round-tripped
# SPIR-V is semantically equivalent to source -> zioshade-GLSL is faithful (any
# render-proxy DIFFER was a spirv-cross artifact, NOT a zioshade bug). DIFFER
# (UNFAITHFUL) = zioshade-GLSL emits GLSL that compiles to a semantically
# different SPIR-V -> a REAL silent-wrong zioshade-GLSL bug.
#
# Fragment only (NagaCompare renders a fragment fn). Crash-classified (a stage
# CRASH is a mandate violation, never hidden as a skip); exit non-zero on crash.
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

ANY_CRASH=0
check_one() {
  local spv="$1" name gs d
  name=$(basename "$spv" .spv)
  gs=$(glslang_stage "$spv")
  [ -z "$gs" ] && { echo "skip-stage"; return; }
  [ "$gs" != "frag" ] && { echo "skip-stage"; return; }  # NagaCompare is fragment-only
  d="$SHARE/$name"

  if ! "$CLI" glsl "$spv" > "$d.z.glsl" 2>"$d.zglsl.err"; then
    if is_crash "$d.zglsl.err" $?; then ANY_CRASH=1; echo "CRASH-zglsl"; else echo "skip-zglsl"; fi; return
  fi
  if ! glslangValidator -V -S frag "$d.z.glsl" -o "$d.z.spv" >"$d.zg.err" 2>&1; then
    if is_crash "$d.zg.err" $?; then ANY_CRASH=1; echo "CRASH-zglslang"; else echo "skip-zglslang"; fi; return
  fi
  if ! "$CLI" msl "$spv" > "$d.ref.msl" 2>"$d.refmsl.err"; then
    if is_crash "$d.refmsl.err" $?; then ANY_CRASH=1; echo "CRASH-refmsl"; else echo "skip-refmsl"; fi; return
  fi
  if ! naga "$d.z.spv" "$d.z.naga.metal" >"$d.naga.err" 2>&1; then
    if is_crash "$d.naga.err" $?; then ANY_CRASH=1; echo "CRASH-naga"; else echo "skip-naga"; fi; return
  fi
  local o; o=$("$NC" "$d.ref.msl" "$d.z.naga.metal" "${d}_r" 2>&1)
  printf '%s' "$o" | grep -q 'MATCH' && { echo "FAITHFUL"; return; }
  printf '%s' "$o" | grep -q 'DIFFER' || { echo "skip-render"; return; }
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$NC" "$d.ref.msl" "$d.z.naga.metal" "${d}_rp" 2>&1)
  if printf '%s' "$os" | grep -q 'MATCH'; then echo "FAITHFUL(edge)"; else echo "UNFAITHFUL(real GLSL bug)"; fi
}

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }
DIR=""
for a in "$@"; do
  if [ -d "$a" ]; then DIR="$a"; else break; fi
done
DIR=${DIR:-tests/cts/graphicsfuzz}
shopt -s nullglob
# Accept either a corpus dir or explicit .spv paths.
if [ $# -ge 1 ] && [ -f "$1" ]; then files=("$@"); else files=("$DIR"/*.spv); fi
for f in "${files[@]}"; do
  v=$(check_one "$f"); key=${v%% *}; bump "$key"
  case "$v" in UNFAITHFUL*|CRASH*) echo "$(basename "$f" .spv).spv: $v";; esac
done
echo ""
echo "=== GLSL faithfulness (.spv): zioshade-MSL(source) vs naga(zioshade-GLSL->spv) ==="
for k in FAITHFUL "FAITHFUL(edge)" "UNFAITHFUL(real GLSL bug)" skip-stage skip-zglsl skip-zglslang skip-refmsl skip-naga skip-render \
         CRASH-zglsl CRASH-zglslang CRASH-refmsl CRASH-naga; do
  echo "  $k: ${C[$k]:-0}"
done
[ "$ANY_CRASH" -eq 0 ] || { echo "FAIL: a stage crashed (mandate violation)"; exit 1; }
