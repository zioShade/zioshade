#!/usr/bin/env bash
# CTS ingestion credibility sweep (r2d.2). The broad-corpus counterpart of the gating
# e54.4.4 sweep (tools/spv_input_validity_sweep.sh): feeds a CREDIBLE, EXTERNAL SPIR-V
# corpus -- the SPIRV-Tools GraphicsFuzz set (the reference validator's own fuzz seed
# corpus, vendored at tests/cts/graphicsfuzz) -- straight through zioshade's binary-
# ingestion path and reports, per backend, how much of it zioshade cross-compiles
# correctly vs refuses loudly (honest-error) vs emits invalid output vs CRASHES on.
#
# The as-written roadmap target (Vulkan CTS spirv_assembly) is inline SPIR-V-assembly
# text inside dEQP C++ test programs, not a standalone .spv corpus; the GraphicsFuzz set
# is the credible, cleanly-obtainable stand-in. The harness is corpus-agnostic -- any
# .spv corpus slots in via the dir argument.
#
# This is a CREDIBILITY REPORT, not a correctness gate. On a broad, unfamiliar corpus
# INVALID output is EXPECTED (breadth the backends don't fully cover yet) and is NON-GATING.
# The ONLY gate signal is a CRASH count that EXCEEDS the committed baseline
# (tests/cts/baseline.txt): a NEW crash on valid input is a mandate violation (silent
# wrong). Existing baseline crashes are tracked beads bugs; lower the baseline when fixed.
#
# GLSL -> glslangValidator (complete oracle). WGSL -> naga (candidate oracle; spirv-cross
# has no WGSL backend to discriminate). MSL (Metal) and HLSL (DXC container) are
# environmental and skip gracefully on Linux, exactly like the e54.4.4 sweep.
#
# Usage: tools/cts_ingestion_sweep.sh [corpus-dir]
#   corpus-dir  directory of .spv binaries (default: tests/cts/graphicsfuzz)
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
BASELINE=tests/cts/baseline.txt
CORPUS=${1:-tests/cts/graphicsfuzz}

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v spirv-dis >/dev/null || { echo "error: spirv-dis not on PATH (stage detection)"; exit 2; }

HAVE_NAGA=0; command -v naga >/dev/null && HAVE_NAGA=1
[ -d "$CORPUS" ] || { echo "error: corpus not found at $CORPUS"; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A zioshade invocation that died by signal / Zig panic rather than refusing loudly. A
# crash on valid input is a mandate violation and must NOT be counted as honest-error.
is_crash() {
  local errfile=$1 rc=$2
  [ "$rc" -gt 128 ] && return 0
  grep -qiE 'thread .main. panicked|reached unreachable|abort trap|trace/breakpoint trap|segmentation fault|sigsegv|sigabrt' "$errfile" 2>/dev/null && return 0
  return 1
}
# Map an .spv's OpEntryPoint execution model to a glslang -S flag for the six standard
# raster/compute stages. Anything else -> empty -> GLSL validation SKIPS the file (a
# validity gate must never invent the stage). WGSL/naga infer the stage and run regardless.
glslang_stage() {
  case "$(spirv-dis "$1" 2>/dev/null | grep -m1 'OpEntryPoint' | awk '{print $2}')" in
    Fragment)               echo "frag";;
    Vertex)                 echo "vert";;
    GLCompute)              echo "comp";;
    Geometry)               echo "geom";;
    TessellationControl)    echo "tesc";;
    TessellationEvaluation) echo "tese";;
    *)                      echo "";;
  esac
}

g_ok=0; g_inv=0; g_herr=0; g_crash=0; g_skip=0
w_ok=0; w_inv=0; w_herr=0; w_crash=0
total=0; val_in=0; val_out=0

shopt -s nullglob
for f in "$CORPUS"/*.spv; do
  total=$((total+1))
  if spirv-val "$f" >/dev/null 2>&1; then val_in=$((val_in+1)); else val_out=$((val_out+1)); fi
  gs=$(glslang_stage "$f")
  # ---- GLSL (glslangValidator; stage-flagged, skips non-standard stages) ----
  if [ -z "$gs" ]; then
    g_skip=$((g_skip+1))
  elif "$CLI" glsl "$f" > "$TMP/o.glsl" 2> "$TMP/e.glsl"; then
    if glslangValidator -S "$gs" "$TMP/o.glsl" >/dev/null 2>&1; then g_ok=$((g_ok+1))
    else g_inv=$((g_inv+1)); fi
  else
    rc=$?
    if is_crash "$TMP/e.glsl" "$rc"; then g_crash=$((g_crash+1)); echo "CRASH-GLSL $(basename "$f") (rc=$rc)"
    else g_herr=$((g_herr+1)); fi
  fi
  # ---- WGSL (naga; runs regardless of stage) ----
  if [ "$HAVE_NAGA" = 1 ]; then
    if "$CLI" wgsl "$f" > "$TMP/o.wgsl" 2> "$TMP/e.wgsl"; then
      if naga "$TMP/o.wgsl" >/dev/null 2>&1; then w_ok=$((w_ok+1))
      else w_inv=$((w_inv+1)); fi
    else
      rc=$?
      if is_crash "$TMP/e.wgsl" "$rc"; then w_crash=$((w_crash+1)); echo "CRASH-WGSL $(basename "$f") (rc=$rc)"
      else w_herr=$((w_herr+1)); fi
    fi
  fi
done

[ "$total" -eq 0 ] && { echo "error: no .spv files in $CORPUS"; exit 2; }

echo
echo "CTS ingestion credibility sweep: $total .spv files ($CORPUS)"
echo "  input validity: spirv-val pass=$val_in fail=$val_out"
echo "  GLSL: ok=$g_ok  invalid-output=$g_inv  honest-error=$g_herr  CRASH=$g_crash  skip=$g_skip"
if [ "$HAVE_NAGA" = 1 ]; then
  echo "  WGSL: ok=$w_ok  candidate-invalid=$w_inv  honest-error=$w_herr  CRASH=$w_crash"
else
  echo "  WGSL: skipped (naga not installed)"
fi
echo "Gate: NEW crash only (count > tests/cts/baseline.txt). invalid-output is non-gating (breadth)."

# Crash-regression gate vs the committed baseline. A backend's current CRASH count may not
# EXCEED its baseline; lowering it (a crash fixed) requires updating the baseline.
bad=0
if [ -f "$BASELINE" ]; then
  while read -r backend count; do
    case "$backend" in ''|\#*) continue;; esac
    case "$backend" in
      glsl) cur=$g_crash;;
      wgsl) cur=$w_crash;;
      *)    continue;;
    esac
    if [ "${cur:-0}" -gt "${count:-0}" ]; then
      echo "REGRESSION: $backend CRASH=$cur exceeds baseline=$count"; bad=1
    fi
  done < "$BASELINE"
else
  echo "NOTE: no baseline at $BASELINE (first run); commit one from this report."
fi
if [ "$bad" -eq 0 ]; then echo "No new crashes vs baseline."; else echo "FAIL: crash regression vs baseline."; fi
exit $bad
