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
#   GLSL  -> glslangValidator                INVALID = real bug
#   WGSL  -> naga                            INVALID = real bug (skipped if naga absent)
#   MSL   -> Metal (MslCompileCheck), spirv-cross-discriminated:
#             zioshade fails Metal -> REAL bug only if spirv-cross's MSL compiles;
#             both fail -> oracle-limit (Metal itself can't express it), not a bug.
#   HLSL  -> dxc, spirv-cross-discriminated  (skipped if dxc absent)
#
# spirv-cross consumes the same .spv directly, so no glslang step is needed for the
# MSL/HLSL reference. Per-file execution model is detected via spirv-dis so each
# emission is validated against the correct stage (frag/vert/comp).
#
# Gate signal = INVALID (real bug: zioshade emits source the reference validator --
# or spirv-cross's reference, for MSL/HLSL -- rejects). The sweep exits non-zero if
# any backend has a real-bug INVALID. Oracle-limit and honest-error (zioshade refused
# to emit) are reported but not fatal: honest-error is the mandate working as designed.
#
# Usage: tools/spv_input_validity_sweep.sh [dir]
#   dir  directory of .spv binaries  (default: .)
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tests/arbitrary_spirv}
CLI=${CLI:-zig-out/bin/zioshade}
CHECK=.zig-cache/mslcheck

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH (MSL/HLSL discriminator)"; exit 2; }
command -v spirv-dis >/dev/null || { echo "error: spirv-dis not on PATH (stage detection)"; exit 2; }

HAVE_NAGA=0; command -v naga >/dev/null && HAVE_NAGA=1
HAVE_METAL=0; command -v swiftc >/dev/null && HAVE_METAL=1
# DXC is often a docker alias; probe it gently.
HAVE_DXC=0
if dxc --help >/dev/null 2>&1; then HAVE_DXC=1; fi

if [ "$HAVE_METAL" = 1 ]; then
  if [ ! -x "$CHECK" ] || [ tools/MslCompileCheck.swift -nt "$CHECK" ]; then
    swiftc -O tools/MslCompileCheck.swift -o "$CHECK" || { echo "error: failed to build MslCompileCheck"; exit 2; }
  fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Per-backend counters.
glsl_valid=0 glsl_invalid=0 glsl_herr=0
wgsl_valid=0 wgsl_invalid=0 wgsl_herr=0 wgsl_skip=0
msl_valid=0 msl_invalid=0 msl_limit=0 msl_herr=0 msl_skip=0
hlsl_valid=0 hlsl_invalid=0 hlsl_limit=0 hlsl_herr=0 hlsl_skip=0
total=0

# Map a .spv's OpEntryPoint execution model to a glslang stage / dxc profile.
# OpEntryPoint layout is `OpEntryPoint <Model> <EntryId> "name" ...`, so the model
# is the SECOND whitespace field ($2) -- NOT $3, which is the entry id. Reading $3
# silently defaulted every non-Fragment shader to "frag" and mis-validated it.
detect_stage() {
  local model
  model=$(spirv-dis "$1" 2>/dev/null | grep -m1 'OpEntryPoint' | awk '{print $2}')
  case "$model" in
    Fragment)  echo "frag";;
    Vertex)    echo "vert";;
    GLCompute) echo "comp";;
    *)         echo "frag";;  # conservative default
  esac
}

dxc_profile() {
  case "$1" in
    frag) echo "ps_6_0";;
    vert) echo "vs_6_0";;
    comp) echo "cs_6_0";;
    *)    echo "ps_6_0";;
  esac
}

shopt -s nullglob
for f in "$DIR"/*.spv; do
  total=$((total+1))
  name=$(basename "$f")
  stage=$(detect_stage "$f")

  # ---- GLSL ----
  if "$CLI" glsl "$f" > "$TMP/o.glsl" 2>/dev/null; then
    if glslangValidator -S "$stage" "$TMP/o.glsl" >/dev/null 2>&1; then
      glsl_valid=$((glsl_valid+1))
    else
      glsl_invalid=$((glsl_invalid+1)); echo "INVALID-GLSL $name"
    fi
  else
    glsl_herr=$((glsl_herr+1))
  fi

  # ---- WGSL ----
  if [ "$HAVE_NAGA" = 1 ]; then
    if "$CLI" wgsl "$f" > "$TMP/o.wgsl" 2>/dev/null; then
      if naga "$TMP/o.wgsl" >/dev/null 2>&1; then
        wgsl_valid=$((wgsl_valid+1))
      else
        wgsl_invalid=$((wgsl_invalid+1)); echo "INVALID-WGSL $name"
      fi
    else
      wgsl_herr=$((wgsl_herr+1))
    fi
  else
    wgsl_skip=$((wgsl_skip+1))
  fi

  # ---- MSL (Metal, spirv-cross-discriminated) ----
  if [ "$HAVE_METAL" = 1 ]; then
    if "$CLI" msl "$f" > "$TMP/o.metal" 2>/dev/null; then
      if "$CHECK" "$TMP/o.metal" >/dev/null 2>&1; then
        msl_valid=$((msl_valid+1))
      elif spirv-cross "$f" --msl > "$TMP/ref.metal" 2>/dev/null && "$CHECK" "$TMP/ref.metal" >/dev/null 2>&1; then
        # zioshade fails Metal but the spirv-cross reference compiles -> real bug.
        msl_invalid=$((msl_invalid+1)); echo "INVALID-MSL $name (spirv-cross ref compiles)"
      else
        msl_limit=$((msl_limit+1))   # both fail -> Metal/oracle limit, not a bug
      fi
    else
      msl_herr=$((msl_herr+1))
    fi
  else
    msl_skip=$((msl_skip+1))
  fi

  # ---- HLSL (dxc, spirv-cross-discriminated) ----
  if [ "$HAVE_DXC" = 1 ]; then
    prof=$(dxc_profile "$stage")
    if "$CLI" hlsl "$f" > "$TMP/o.hlsl" 2>/dev/null; then
      if dxc -T "$prof" -E main "$TMP/o.hlsl" >/dev/null 2>&1; then
        hlsl_valid=$((hlsl_valid+1))
      elif spirv-cross "$f" --hlsl --shader-model 60 > "$TMP/ref.hlsl" 2>/dev/null && dxc -T "$prof" -E main "$TMP/ref.hlsl" >/dev/null 2>&1; then
        hlsl_invalid=$((hlsl_invalid+1)); echo "INVALID-HLSL $name (spirv-cross ref compiles)"
      else
        hlsl_limit=$((hlsl_limit+1))
      fi
    else
      hlsl_herr=$((hlsl_herr+1))
    fi
  else
    hlsl_skip=$((hlsl_skip+1))
  fi
done

echo
echo "Arbitrary-SPIR-V backend validity sweep: $total .spv files in $DIR"
echo "  GLSL: valid=$glsl_valid  INVALID=$glsl_invalid  honest-error=$glsl_herr"
if [ "$HAVE_NAGA" = 1 ]; then
  echo "  WGSL: valid=$wgsl_valid  INVALID=$wgsl_invalid  honest-error=$wgsl_herr"
else
  echo "  WGSL: skipped (naga not installed)"
fi
if [ "$HAVE_METAL" = 1 ]; then
  echo "  MSL:  valid=$msl_valid  INVALID=$msl_invalid  oracle-limit=$msl_limit  honest-error=$msl_herr"
else
  echo "  MSL:  skipped (swiftc/Metal not available)"
fi
if [ "$HAVE_DXC" = 1 ]; then
  echo "  HLSL: valid=$hlsl_valid  INVALID=$hlsl_invalid  oracle-limit=$hlsl_limit  honest-error=$hlsl_herr"
else
  echo "  HLSL: skipped (dxc not available)"
fi
echo "Gate signal is INVALID (real bug: emitted source the reference rejects)."

# Any real-bug INVALID fails the gate.
bad=0
[ "$glsl_invalid" -gt 0 ] && bad=1
[ "$HAVE_NAGA" = 1 ] && [ "$wgsl_invalid" -gt 0 ] && bad=1
[ "$HAVE_METAL" = 1 ] && [ "$msl_invalid" -gt 0 ] && bad=1
[ "$HAVE_DXC" = 1 ] && [ "$hlsl_invalid" -gt 0 ] && bad=1
[ "$bad" -eq 0 ]
