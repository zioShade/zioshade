#!/usr/bin/env bash
# MSL backend-validity sweep: cross-compile every shader in a corpus to MSL and
# compile-check the output with Metal (MTLDevice.makeLibrary via tools/MslCompileCheck.swift).
# This is the MSL analog of tools/glsl_glslang_sweep.sh (GLSL->glslangValidator) and
# tools/wgsl_naga_sweep.sh (WGSL->naga): a real backend-validity oracle that catches
# the silent-wrong class (emit valid-looking MSL at exit 0 that the Metal compiler rejects).
#
# DISCRIMINATION (spirv-cross reference): every Metal rejection is checked against the
# spirv-cross reference — the same source cross-compiled by spirv-cross to MSL. Only if
# spirv-cross's MSL compiles on Metal while zioshade's fails is it counted as a REAL
# zioshade bug (the gate signal). If both fail, it is a Metal limitation (feature Metal
# itself can't express for this shader) — NOT a zioshade bug — and counted separately.
# This mirrors tools/hlsl_glslang_sweep.sh / tools/glsl_glslang_sweep.sh and keeps the
# gate honest (no chasing Metal-limits as if they were emitter bugs).
#
# Classification:
#   valid          = Metal accepts zioshade's MSL
#   INVALID        = REAL bug: spirv-cross reference MSL compiles but zioshade's fails
#   metal-limit    = both zioshade and spirv-cross MSL fail Metal — a Metal limitation,
#                    NOT a zioshade bug (counted, not fatal)
#   inconclusive   = the spirv-cross reference could not be built (SPIR-V build or
#                    spirv-cross failed) so the case can't be classified
#   honest-error   = zioshade frontend refused — no MSL emitted
#
# Requires: a built CLI (zig build cli), swiftc + a Metal device (macOS), spirv-cross on PATH.
#
# Usage: tools/msl_validity_sweep.sh [dir] [stage] [ext]
#   dir    corpus directory   (default: tests/spirv-cross)
#   stage  shader stage       (default: fragment)
#   ext    file extension     (default: frag)
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tests/spirv-cross}
STAGE=${2:-fragment}
EXT=${3:-frag}
CLI=${CLI:-zig-out/bin/zioshade}
CHECK=.zig-cache/mslcheck

case "$STAGE" in
  fragment) GSTAGE=frag;;
  vertex)   GSTAGE=vert;;
  compute)  GSTAGE=comp;;
  *)        GSTAGE="$STAGE";;
esac

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v swiftc >/dev/null || { echo "error: swiftc not on PATH"; exit 2; }
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH (needed for the reference discriminator)"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH (needed to build the reference SPIR-V)"; exit 2; }
# Build the Metal compile-checker if missing or stale.
if [ ! -x "$CHECK" ] || [ tools/MslCompileCheck.swift -nt "$CHECK" ]; then
  swiftc -O tools/MslCompileCheck.swift -o "$CHECK" || { echo "error: failed to build MslCompileCheck"; exit 2; }
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

valid=0 invalid=0 mlim=0 incon=0 herr=0 total=0
for f in "$DIR"/*."$EXT"; do
  [ -e "$f" ] || continue
  case "$f" in *.asm.*) continue;; esac   # SPIR-V assembly, not GLSL source
  total=$((total+1))
  name=$(basename "$f")

  # 1. zioshade emits MSL (frontend refusal = honest-error).
  if ! "$CLI" msl "$f" --stage "$STAGE" > "$TMP/o.metal" 2>/dev/null; then
    herr=$((herr+1)); continue
  fi

  # 2. Metal checks zioshade's MSL.
  if "$CHECK" "$TMP/o.metal" >/dev/null 2>&1; then
    valid=$((valid+1)); continue
  fi

  # 3. zioshade failed Metal -> discriminate against the spirv-cross reference.
  if ! glslangValidator -V -S "$GSTAGE" "$f" -o "$TMP/r.spv" >/dev/null 2>&1; then
    incon=$((incon+1)); echo "INCONCLUSIVE $name (SPIR-V build failed)"; continue
  fi
  if ! spirv-cross "$TMP/r.spv" --msl > "$TMP/ref.metal" 2>/dev/null; then
    incon=$((incon+1)); echo "INCONCLUSIVE $name (spirv-cross failed)"; continue
  fi
  if "$CHECK" "$TMP/ref.metal" >/dev/null 2>&1; then
    # Reference compiles, zioshade fails -> real zioshade bug (the gate signal).
    invalid=$((invalid+1)); echo "INVALID $name"
  else
    # Both fail -> Metal limitation, not zioshade's fault.
    mlim=$((mlim+1)); echo "METAL-LIMIT $name"
  fi
done

echo
echo "MSL (spirv-cross-discriminated):"
echo "  valid=$valid  INVALID(real-bug)=$invalid  metal-limit=$mlim  inconclusive=$incon  honest-error=$herr  / $total"
echo "Gate signal is INVALID (real-bug: spirv-cross ref compiles but zioshade fails)."
[ "$invalid" -eq 0 ]
