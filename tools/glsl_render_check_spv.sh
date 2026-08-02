#!/usr/bin/env bash
# GLSL render proxy for BINARY SPIR-V inputs (.spv) -- the .spv counterpart of
# tools/glsl_render_check.sh (which starts from .frag). Checks zioshade's GLSL
# output is RENDER-EQUIVALENT to spirv-cross (the incumbent reference) by round-
# tripping through Metal: source .spv ->(spirv-cross --msl)-> MSL_ref; and source
# .spv ->(zioshade glsl)-> z.glsl ->(glslang -V)-> z.spv ->(spirv-cross --msl)->
# z.msl; then render-diff MSL_ref vs z.msl on Metal via ShaderCompare. MATCH =
# zioshade's GLSL renders identically to spirv-cross's MSL of the same source.
#
# NOT GROUND TRUTH (N=2): both arms pass through spirv-cross --msl, so a spirv-
# cross MSL-lowering bug shared by both arms cancels out of the diff (correlated
# error). spirv-cross is also the 1-of-1 reference, so its own bugs are encoded
# as "correct". For ground truth use tools/glsl_faithfulness.sh (independent naga
# arm, no spirv-cross on the critical path) -- which exists for .frag today.
#
# NECESSARY BUT NOT SUFFICIENT: (a) ShaderCompare renders ONE fixed input config
# (one texture + uniform set), so an input-dependent phi bug can MATCH on the
# exercised config; (b) glslang -V runs its front-end (folding/DCE), which could
# re-canonicalize a subtly-wrong z.glsl. So a MATCH is strong evidence, not proof;
# a DIFFER is the silent-wrong lead worth chasing (via glsl_faithfulness.sh +
# source-output inspection).
#
# Fragments only: ShaderCompare is fragment-only (its pipeline force-unwraps a
# fragment function); non-frag stages are skip-stage, never sent to the renderer.
#
# Usage: tools/glsl_render_check_spv.sh [corpus-dir]   (default: tests/cts/graphicsfuzz)
# Exit: non-zero iff any input CRASHES a stage (a mandate violation) -- mirrors
# cts_ingestion_sweep's crash-regression gate. DIFFER / skip-* are report-only (0).
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_glsl_render_spv}
mkdir -p "$SHARE"
SC=$SHARE/ShaderCompare
[ -x "$SC" ] || swiftc -O tools/ShaderCompare.swift -o "$SC" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH"; exit 2; }
command -v spirv-dis >/dev/null || { echo "error: spirv-dis not on PATH (stage detection)"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }

# A stage invocation that died by signal / panic rather than refusing loudly.
# Ported from cts_ingestion_sweep.sh: a CRASH on valid input is a mandate
# violation and must NOT be counted as an honest skip (which is what this tool
# existed to discriminate). stderr is captured (not discarded) so it can classify.
# NOTE: callers MUST capture rc in a variable (`cmd ...; rc=$?`) BEFORE the
# surrounding `if !`/pipeline clobbers $? -- otherwise rc is always 0 here and
# the rc>128 (signal) arm is dead (only the stderr-grep arm would fire).
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
  # ShaderCompare is fragment-only (its pipeline force-unwraps a fragment fn);
  # non-frag stages would crash the renderer, so skip them.
  [ "$gs" != "frag" ] && { echo "skip-stage"; return; }
  d="$SHARE/$name"

  # spirv-cross/glslang are ORACLES -- their crash is reported but NOT fatal
  # (zioshade is blameless for its oracles' stability). Only CRASH-zglsl (a
  # zioshade-owned stage) fails the run.
  spirv-cross --msl "$spv" > "$d.ref.msl" 2>"$d.ref.err"; rc=$?
  if [ $rc -ne 0 ]; then
    if is_crash "$d.ref.err" "$rc"; then echo "CRASH-crossmsl"; else echo "skip-crossmsl"; fi; return
  fi
  "$CLI" glsl "$spv" > "$d.z.glsl" 2>"$d.zglsl.err"; rc=$?
  if [ $rc -ne 0 ]; then
    if is_crash "$d.zglsl.err" "$rc"; then ANY_ZS_CRASH=1; echo "CRASH-zglsl"; else echo "skip-zglsl"; fi; return
  fi
  glslangValidator -V -S "$gs" "$d.z.glsl" -o "$d.z.spv" >"$d.zg.err" 2>&1; rc=$?
  if [ $rc -ne 0 ]; then
    if is_crash "$d.zg.err" "$rc"; then echo "CRASH-zglslang"; else echo "skip-zglslang"; fi; return
  fi
  spirv-cross --msl "$d.z.spv" > "$d.z.msl" 2>"$d.zcm.err"; rc=$?
  if [ $rc -ne 0 ]; then
    if is_crash "$d.zcm.err" "$rc"; then echo "CRASH-zcrossmsl"; else echo "skip-zcrossmsl"; fi; return
  fi
  local o; o=$("$SC" "$d.z.msl" "$d.ref.msl" "${d}_r" 2>&1)
  printf '%s' "$o" | grep -q '^MATCH' && { echo "MATCH"; return; }
  printf '%s' "$o" | grep -q 'SKIP(harness-binding)' && { echo "skip-binding"; return; }
  printf '%s' "$o" | grep -qE '^DIFFER' || { echo "skip-render"; return; }
  local md; md=$(printf '%s' "$o" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$SC" "$d.z.msl" "$d.ref.msl" "${d}_rp" 2>&1)
  if printf '%s' "$os" | grep -q '^MATCH'; then echo "EDGE(fast-math-fp)"; else echo "DIFFER maxdiff=${md:-?}"; fi
}

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }
DIR=${1:-tests/cts/graphicsfuzz}
shopt -s nullglob
for f in "$DIR"/*.spv; do
  v=$(check_one "$f"); key=${v%% *}; bump "$key"
  case "$v" in CRASH*) echo "$(basename "$f" .spv).spv: $v";; esac
done
echo ""
echo "=== GLSL render proxy (.spv) coverage: $DIR ==="
for k in MATCH "EDGE(fast-math-fp)" DIFFER skip-binding skip-stage skip-crossmsl skip-zglsl skip-zglslang skip-zcrossmsl skip-render \
         CRASH-zglsl CRASH-crossmsl CRASH-zglslang CRASH-zcrossmsl; do
  echo "  $k: ${C[$k]:-0}"
done
[ "$ANY_ZS_CRASH" -eq 0 ] || { echo "FAIL: a zioshade stage crashed (mandate violation)"; exit 1; }
