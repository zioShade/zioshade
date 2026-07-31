#!/usr/bin/env bash
# SPIR-V-input backend validity sweep: the .spv-binary analog of the GLSL-source
# sweeps (tools/msl_validity_sweep.sh, tools/backend_validity_sweep.sh).
#
# All existing validity sweeps start from GLSL *source* -- zioshade's or glslang's
# frontend produces the SPIR-V -- so ARBITRARY / external SPIR-V consumption (the
# output of glslang / DXC / spirv-opt, or any SPIR-V zioshade's own frontend would
# never emit) was never validity-gated. That is the e54.4 (G2) gap: a backend that
# assumes zioshade-generated structure could emit source its own ecosystem validator
# rejects (or that silently miscompiles) on arbitrary input -- the exact silent-wrong
# class this project exists to prevent.
#
# This sweep feeds arbitrary .spv binaries straight through the four backends (the
# CLI's binary-ingestion path, NOT the GLSL frontend) and compile-checks each emitted
# backend source with that ecosystem's reference compiler:
#
#   GLSL  -> glslangValidator                 INVALID = real bug (complete oracle)
#   WGSL  -> naga                             CANDIDATE bug -- naga is an INCOMPLETE
#                                             oracle and spirv-cross has NO WGSL backend
#                                             to discriminate against (see caveat below)
#   MSL   -> Metal (MslCompileCheck), spirv-cross-discriminated:
#             zioshade fails Metal -> REAL bug only if spirv-cross's MSL compiles;
#             spirv-cross can't emit -> INCONCLUSIVE; both fail -> oracle-limit.
#   HLSL  -> dxc (in the dxc-oracle container), spirv-cross-discriminated.
#
# A CRASH (Zig panic / unreachable / signal) inside zioshade on valid input is itself a
# mandate violation and is detected separately (stderr signature + signal exit code) --
# never silently counted as honest-error.
#
# Per-file execution model is detected via spirv-dis. The SIX standard raster/compute
# stages map to glslang -S flags / dxc profiles; ANY OTHER model (ray-tracing, mesh,
# task, or unrecognized, or a spirv-dis failure) SKIPS the stage-flagged validators
# (GLSL, HLSL) rather than guessing -- a validity gate must never invent the stage
# (the plausible-but-wrong anti-pattern). WGSL/MSL validators infer the stage from the
# shader and run regardless.
#
# Gate signal = INVALID (real bug) or any CRASH. Oracle-limit, inconclusive, and
# honest-error (zioshade refused to emit) are reported but not fatal: honest-error is
# the mandate working as designed. NOT wired to `just ci` while known bugs are open
# (beads zioshade-e54.4); run via `just spv-validity`.
#
# Usage: tools/spv_input_validity_sweep.sh [dir]
#   dir  directory of .spv binaries  (default: tests/arbitrary_spirv)
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tests/arbitrary_spirv}
CLI=${CLI:-zig-out/bin/zioshade}
CHECK=.zig-cache/mslcheck
CONTAINER=${CONTAINER:-dxc-oracle}

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH (MSL/HLSL discriminator)"; exit 2; }
command -v spirv-dis >/dev/null || { echo "error: spirv-dis not on PATH (stage detection)"; exit 2; }

HAVE_NAGA=0; command -v naga >/dev/null && HAVE_NAGA=1
HAVE_METAL=0; command -v swiftc >/dev/null && HAVE_METAL=1
# DXC ships no macOS build; tools/hlsl_validity_sweep.sh runs /opt/dxc/bin/dxc in the
# `dxc-oracle` container (it needs LD_LIBRARY_PATH=/opt/dxc/lib; it is NOT on PATH).
# Probe the BINARY itself, not just the container: a running container whose dxc isn't
# invokable would otherwise make every HLSL case false-classify as oracle-limit (silent
# masking -- the exact failure mode this gate exists to prevent). NB: on this host `dxc`
# is also an interactive shell ALIAS for `docker container exec`, which does not expand
# in non-interactive bash, so `dxc --help` would always silently fail too.
HAVE_DXC=0
docker exec -e LD_LIBRARY_PATH=/opt/dxc/lib "$CONTAINER" /opt/dxc/bin/dxc --version >/dev/null 2>&1 && HAVE_DXC=1

if [ "$HAVE_METAL" = 1 ]; then
  if [ ! -x "$CHECK" ] || [ tools/MslCompileCheck.swift -nt "$CHECK" ]; then
    swiftc -O tools/MslCompileCheck.swift -o "$CHECK" || { echo "error: failed to build MslCompileCheck"; exit 2; }
  fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

crashes=0
glsl_valid=0 glsl_invalid=0 glsl_herr=0 glsl_skip=0
wgsl_valid=0 wgsl_invalid=0 wgsl_herr=0 wgsl_skip=0
msl_valid=0 msl_invalid=0 msl_limit=0 msl_incon=0 msl_herr=0 msl_skip=0
hlsl_valid=0 hlsl_invalid=0 hlsl_limit=0 hlsl_incon=0 hlsl_herr=0 hlsl_skip=0
total=0

# True if a zioshade invocation crashed (signal exit, or a Zig panic signature on
# stderr) rather than refusing loudly. A crash on valid input is a mandate violation
# and must NOT be counted as honest-error.
is_crash() {
  local errfile=$1 rc=$2
  [ "$rc" -gt 128 ] && return 0          # 128+sig = killed by signal
  grep -qiE 'thread .main. panicked|reached unreachable|abort trap|trace/breakpoint trap|segmentation fault|sigsegv|sigabrt' "$errfile" 2>/dev/null && return 0
  return 1
}

# Map a .spv's OpEntryPoint execution model to a glslang -S flag for the SIX standard
# raster/compute stages. Anything else returns empty -> GLSL validation SKIPS the file.
# OpEntryPoint layout is `OpEntryPoint <Model> <EntryId> "name" ...`; the model is the
# second whitespace field ($2), NOT $3 (the entry id).
glslang_stage() {
  case "$(spirv-dis "$1" 2>/dev/null | grep -m1 'OpEntryPoint' | awk '{print $2}')" in
    Fragment)             echo "frag";;
    Vertex)               echo "vert";;
    GLCompute)            echo "comp";;
    Geometry)             echo "geom";;
    TessellationControl)  echo "tesc";;
    TessellationEvaluation) echo "tese";;
    *)                    echo "";;
  esac
}

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

shopt -s nullglob
for f in "$DIR"/*.spv; do
  total=$((total+1))
  name=$(basename "$f")
  gstage=$(glslang_stage "$f")

  # Warn on multi-entry-point modules: validation uses the first model only.
  ep_models=$(spirv-dis "$f" 2>/dev/null | grep 'OpEntryPoint' | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
  if [ "${ep_models:-0}" -gt 1 ]; then echo "MULTI-EP $name ($ep_models distinct models; validating first only)"; fi

  # ---- GLSL (glslangValidator; stage-flagged -> skipped for non-standard stages) ----
  if [ -z "$gstage" ]; then
    glsl_skip=$((glsl_skip+1))
  elif "$CLI" glsl "$f" > "$TMP/o.glsl" 2> "$TMP/err.glsl"; then
    if glslangValidator -S "$gstage" "$TMP/o.glsl" >/dev/null 2>&1; then glsl_valid=$((glsl_valid+1))
    else glsl_invalid=$((glsl_invalid+1)); echo "INVALID-GLSL $name"; fi
  else
    rc=$?
    if is_crash "$TMP/err.glsl" "$rc"; then crashes=$((crashes+1)); echo "CRASH-GLSL $name (rc=$rc)"; else glsl_herr=$((glsl_herr+1)); fi
  fi

  # ---- WGSL (naga; runs regardless of stage) ----
  if [ "$HAVE_NAGA" = 1 ]; then
    if "$CLI" wgsl "$f" > "$TMP/o.wgsl" 2> "$TMP/err.wgsl"; then
      if naga "$TMP/o.wgsl" >/dev/null 2>&1; then wgsl_valid=$((wgsl_valid+1))
      else wgsl_invalid=$((wgsl_invalid+1)); echo "INVALID-WGSL $name"; fi
    else
      rc=$?
      if is_crash "$TMP/err.wgsl" "$rc"; then crashes=$((crashes+1)); echo "CRASH-WGSL $name (rc=$rc)"; else wgsl_herr=$((wgsl_herr+1)); fi
    fi
  else
    wgsl_skip=$((wgsl_skip+1))
  fi

  # ---- MSL (Metal, spirv-cross-discriminated; runs regardless of stage) ----
  if [ "$HAVE_METAL" = 1 ]; then
    if "$CLI" msl "$f" > "$TMP/o.metal" 2> "$TMP/err.msl"; then
      if "$CHECK" "$TMP/o.metal" >/dev/null 2>&1; then msl_valid=$((msl_valid+1))
      elif ! spirv-cross "$f" --msl > "$TMP/ref.metal" 2>/dev/null; then msl_incon=$((msl_incon+1))   # ref can't emit
      elif "$CHECK" "$TMP/ref.metal" >/dev/null 2>&1; then msl_invalid=$((msl_invalid+1)); echo "INVALID-MSL $name (spirv-cross ref compiles)"
      else msl_limit=$((msl_limit+1))   # both fail -> Metal/oracle limit
      fi
    else
      rc=$?
      if is_crash "$TMP/err.msl" "$rc"; then crashes=$((crashes+1)); echo "CRASH-MSL $name (rc=$rc)"; else msl_herr=$((msl_herr+1)); fi
    fi
  else
    msl_skip=$((msl_skip+1))
  fi

  # ---- HLSL (dxc in container, spirv-cross-discriminated; stage-profiled) ----
  if [ "$HAVE_DXC" = 1 ] && [ -n "$gstage" ]; then
    prof=$(dxc_profile "$gstage")
    if "$CLI" hlsl "$f" > "$TMP/o.hlsl" 2> "$TMP/err.hlsl"; then
      docker cp "$TMP/o.hlsl" "$CONTAINER:/tmp/zs.hlsl" >/dev/null 2>&1
      if docker exec -e LD_LIBRARY_PATH=/opt/dxc/lib "$CONTAINER" /opt/dxc/bin/dxc -Wno-ignored-attributes -T "$prof" -E main /tmp/zs.hlsl -Fo /dev/null >/dev/null 2>&1; then hlsl_valid=$((hlsl_valid+1))
      elif ! spirv-cross "$f" --hlsl --shader-model 60 > "$TMP/ref.hlsl" 2>/dev/null; then hlsl_incon=$((hlsl_incon+1))
      else
        docker cp "$TMP/ref.hlsl" "$CONTAINER:/tmp/zs_ref.hlsl" >/dev/null 2>&1
        if docker exec -e LD_LIBRARY_PATH=/opt/dxc/lib "$CONTAINER" /opt/dxc/bin/dxc -Wno-ignored-attributes -T "$prof" -E main /tmp/zs_ref.hlsl -Fo /dev/null >/dev/null 2>&1; then hlsl_invalid=$((hlsl_invalid+1)); echo "INVALID-HLSL $name (spirv-cross ref compiles)"
        else hlsl_limit=$((hlsl_limit+1)); fi
      fi
    else
      rc=$?
      if is_crash "$TMP/err.hlsl" "$rc"; then crashes=$((crashes+1)); echo "CRASH-HLSL $name (rc=$rc)"; else hlsl_herr=$((hlsl_herr+1)); fi
    fi
  else
    hlsl_skip=$((hlsl_skip+1))
  fi
done

[ "$total" -eq 0 ] && { echo "error: no .spv files in $DIR"; exit 2; }

echo
echo "Arbitrary-SPIR-V backend validity sweep: $total .spv files in $DIR"
echo "  GLSL: valid=$glsl_valid  INVALID=$glsl_invalid  honest-error=$glsl_herr  skip=$glsl_skip"
if [ "$HAVE_NAGA" = 1 ]; then
  echo "  WGSL: valid=$wgsl_valid  candidate-INVALID=$wgsl_invalid  honest-error=$wgsl_herr"
else
  echo "  WGSL: skipped (naga not installed)"
fi
if [ "$HAVE_METAL" = 1 ]; then
  echo "  MSL:  valid=$msl_valid  INVALID=$msl_invalid  oracle-limit=$msl_limit  inconclusive=$msl_incon  honest-error=$msl_herr"
else
  echo "  MSL:  skipped (swiftc/Metal not available)"
fi
if [ "$HAVE_DXC" = 1 ]; then
  echo "  HLSL: valid=$hlsl_valid  INVALID=$hlsl_invalid  oracle-limit=$hlsl_limit  inconclusive=$hlsl_incon  honest-error=$hlsl_herr"
else
  echo "  HLSL: skipped (dxc-oracle container not running; HLSL is environmental)"
fi
[ "$crashes" -gt 0 ] && echo "  CRASH: $crashes  (zioshade crashed on valid input -- mandate violation)"
if [ "$wgsl_invalid" -gt 0 ]; then
  echo "  NOTE: WGSL INVALID is a CANDIDATE bug -- naga is an incomplete oracle and spirv-cross"
  echo "        has no WGSL backend to discriminate. Confirm by source inspection."
fi
echo "Gate signal is INVALID/CRASH. Oracle-limit, inconclusive, honest-error are not fatal."

bad=0
[ "$crashes" -gt 0 ] && bad=1
[ "$glsl_invalid" -gt 0 ] && bad=1
[ "$HAVE_NAGA" = 1 ] && [ "$wgsl_invalid" -gt 0 ] && bad=1
[ "$HAVE_METAL" = 1 ] && [ "$msl_invalid" -gt 0 ] && bad=1
[ "$HAVE_DXC" = 1 ] && [ "$hlsl_invalid" -gt 0 ] && bad=1
[ "$bad" -eq 0 ]
