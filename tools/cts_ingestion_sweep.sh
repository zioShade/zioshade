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
# The ONLY gate signal is a crash NOT LISTED in the committed file-level baseline
# (tests/cts/baseline.txt `crash-files:<backend>` sections): a NEW crash on valid input is
# a mandate violation (silent wrong). Existing baseline crashes are tracked beads bugs;
# prune them from the baseline when fixed (the gate prints a reminder).
#
# GLSL -> glslangValidator (complete oracle). WGSL -> naga (candidate oracle; spirv-cross
# has no WGSL backend to discriminate). MSL -> the Metal compiler and HLSL -> DXC, via
# tools/msl_compile_check.sh and tools/hlsl_compile_check.sh, which resolve whichever
# compiler the machine actually has (macOS Metal toolchain / Metal device; a native dxc
# on PATH, e.g. the Windows Vulkan SDK's, or the dxc-oracle container). Both are
# environmental and skip gracefully where their compiler is absent (e.g. a Linux runner),
# exactly like the e54.4.4 sweep -- a missing optional oracle is never a false fail, but
# it is also never counted as a pass.
#
# These are COMPILE-validation legs only. Render-differential (does the compiled shader
# produce the same pixels) needs a GPU and stays a local-only gate (`just prove`,
# `just prove-naga`, tools/*_render_check.sh); hosted CI runners have no usable GPU.
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
# Probe the MSL/HLSL oracles ONCE (each probe compiles a trivial known-good shader) and
# pin the winner for every per-file call, so the sweep can never use an oracle the probe
# did not validate.
HAVE_METAL=0
if MSL_ORACLE=$(bash tools/msl_compile_check.sh --probe 2>/dev/null); then
  HAVE_METAL=1; export ZIOSHADE_MSL_ORACLE="$MSL_ORACLE"
fi
HAVE_DXC=0
if HLSL_ORACLE=$(bash tools/hlsl_compile_check.sh --probe 2>/dev/null); then
  HAVE_DXC=1; export ZIOSHADE_HLSL_ORACLE="$HLSL_ORACLE"
fi
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

# DXC target profile for each of the six standard stages (HLSL is stage-profiled, so a
# file whose execution model is not one of them SKIPS the HLSL leg rather than guessing).
dxc_profile() {
  case "$1" in
    frag) echo "ps_6_0";;
    vert) echo "vs_6_0";;
    comp) echo "cs_6_0";;
    geom) echo "gs_6_0";;
    tesc) echo "hs_6_0";;
    tese) echo "ds_6_0";;
    *)    echo "";;
  esac
}

g_ok=0; g_inv=0; g_herr=0; g_crash=0; g_skip=0; g_crash_files=""
w_ok=0; w_inv=0; w_herr=0; w_crash=0; w_crash_files=""
m_ok=0; m_inv=0; m_herr=0; m_crash=0; m_crash_files=""
h_ok=0; h_inv=0; h_herr=0; h_crash=0; h_skip=0; h_crash_files=""
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
    if is_crash "$TMP/e.glsl" "$rc"; then g_crash=$((g_crash+1)); echo "CRASH-GLSL $(basename "$f") (rc=$rc)"; g_crash_files="${g_crash_files} $(basename "$f")"
    else g_herr=$((g_herr+1)); fi
  fi
  # ---- WGSL (naga; runs regardless of stage) ----
  if [ "$HAVE_NAGA" = 1 ]; then
    if "$CLI" wgsl "$f" > "$TMP/o.wgsl" 2> "$TMP/e.wgsl"; then
      if naga "$TMP/o.wgsl" >/dev/null 2>&1; then w_ok=$((w_ok+1))
      else w_inv=$((w_inv+1)); fi
    else
      rc=$?
      if is_crash "$TMP/e.wgsl" "$rc"; then w_crash=$((w_crash+1)); echo "CRASH-WGSL $(basename "$f") (rc=$rc)"; w_crash_files="${w_crash_files} $(basename "$f")"
      else w_herr=$((w_herr+1)); fi
    fi
  fi
  # ---- MSL (Metal compiler; runs regardless of stage) ----
  if [ "$HAVE_METAL" = 1 ]; then
    if "$CLI" msl "$f" > "$TMP/o.metal" 2> "$TMP/e.msl"; then
      if bash tools/msl_compile_check.sh "$TMP/o.metal" >/dev/null 2>&1; then m_ok=$((m_ok+1))
      else m_inv=$((m_inv+1)); fi
    else
      rc=$?
      if is_crash "$TMP/e.msl" "$rc"; then m_crash=$((m_crash+1)); echo "CRASH-MSL $(basename "$f") (rc=$rc)"; m_crash_files="${m_crash_files} $(basename "$f")"
      else m_herr=$((m_herr+1)); fi
    fi
  fi
  # ---- HLSL (DXC; stage-profiled, skips non-standard stages) ----
  hp=$(dxc_profile "$gs")
  if [ "$HAVE_DXC" = 1 ] && [ -n "$hp" ]; then
    if "$CLI" hlsl "$f" > "$TMP/o.hlsl" 2> "$TMP/e.hlsl"; then
      if bash tools/hlsl_compile_check.sh "$hp" "$TMP/o.hlsl" >/dev/null 2>&1; then h_ok=$((h_ok+1))
      else h_inv=$((h_inv+1)); fi
    else
      rc=$?
      if is_crash "$TMP/e.hlsl" "$rc"; then h_crash=$((h_crash+1)); echo "CRASH-HLSL $(basename "$f") (rc=$rc)"; h_crash_files="${h_crash_files} $(basename "$f")"
      else h_herr=$((h_herr+1)); fi
    fi
  else
    h_skip=$((h_skip+1))
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
if [ "$HAVE_METAL" = 1 ]; then
  echo "  MSL:  ok=$m_ok  invalid-output=$m_inv  honest-error=$m_herr  CRASH=$m_crash  (oracle: $ZIOSHADE_MSL_ORACLE)"
else
  echo "  MSL:  skipped (no Metal compiler: neither xcrun metal nor swiftc+Metal device)"
fi
if [ "$HAVE_DXC" = 1 ]; then
  echo "  HLSL: ok=$h_ok  invalid-output=$h_inv  honest-error=$h_herr  CRASH=$h_crash  skip=$h_skip  (oracle: $ZIOSHADE_HLSL_ORACLE)"
else
  echo "  HLSL: skipped (no DXC: not on PATH and no dxc-oracle container)"
fi
echo "Gate: file-level crash baseline (tests/cts/baseline.txt crash-files sections). invalid-output is non-gating (breadth)."

# Crash-regression gate vs the committed baseline, FILE-LEVEL. The baseline lists the exact
# corpus files each backend crashes on (a `crash-files:<backend>` section); any file that
# crashes NOW but is not listed is a NEW crash (mandate violation) and fails the gate. This
# closes the old count-based hole, where a fix + a different new crash at the same count
# passed silently. A baseline file that no longer crashes is a FIXED crash: it does not
# fail, it prints a reminder to prune the baseline (keeping it honest keeps the diff
# meaningful).
bad=0
for backend in glsl wgsl msl hlsl; do
  case $backend in
    glsl) cur_files=$g_crash_files;;
    wgsl) cur_files=$w_crash_files;;
    # A skipped backend reports no crash files and so can never fail the gate: an
    # absent oracle cannot fail the gate, and cannot certify the backend either.
    msl)  cur_files=$m_crash_files;;
    hlsl) cur_files=$h_crash_files;;
  esac
  # Extract this backend's section from the baseline: lines after `crash-files:<backend>`
  # until the next section marker (a line containing ':').
  base_files=$(sed -n "/^crash-files:$backend\$/,/^[^#].*:/{/^crash-files:$backend$/d;/^[^#].*:/d;p;}" "$BASELINE" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$' || true)
  for f in $cur_files; do
    if ! printf '%s\n' "$base_files" | grep -qx "$f"; then
      echo "REGRESSION: NEW crash on $backend: $f (not in baseline)"; bad=1
    fi
  done
  for f in $base_files; do
    if ! printf '%s\n' "$cur_files" | grep -qx "$f"; then
      echo "NOTE: baseline crash $backend/$f no longer crashes (fixed?) -- prune $BASELINE."
    fi
  done
done
if [ "$bad" -eq 0 ]; then echo "No new crashes vs baseline (file-level)."; else echo "FAIL: crash regression vs baseline."; fi
exit $bad
