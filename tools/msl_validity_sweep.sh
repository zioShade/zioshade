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
#                    spirv-cross failed) so the case can't be classified. RATCHETED
#                    (#690): an inconclusive case not in KNOWN_INCONCLUSIVE below
#                    fails the gate (see the comment at the discrimination step).
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

valid=0 invalid=0 mlim=0 incon=0 herr=0 total=0 incon_regression=0

# KNOWN_INCONCLUSIVE ratchet (#690): the CURRENT per-stage set of shaders whose
# spirv-cross reference cannot be built, so neither leg can judge them. See the
# comment at the discrimination step below for why this class must not be a free
# pass. An INCONCLUSIVE not in this stage's list is a NEW unjudgeable case and
# FAILS the gate; the set may only shrink, and an entry that no longer lands in
# the class prints a prune note after the run. Keep per-stage (mirrors the
# stage-aware baselines of tools/hlsl_glslang_sweep.sh / tools/glsl_glslang_sweep.sh).
case "$STAGE" in
  fragment)
    KNOWN_INCONCLUSIVE=" switch_loop.frag";;
  vertex)
    KNOWN_INCONCLUSIVE=" inverse.legacy.vert shader-draw-parameters-450.desktop.vk.vert shader-draw-parameters.desktop.vk.vert";;
  compute)
    # No INCONCLUSIVE MSL compute cases currently.
    KNOWN_INCONCLUSIVE=" ";;
  *)
    KNOWN_INCONCLUSIVE=" ";;
esac
is_known_incon() { case " $KNOWN_INCONCLUSIVE " in *" $1 "*) return 0;; *) return 1;; esac; }

incon_seen=""
# Record one reference-unbuildable case. Ratcheted (#690): an entry outside
# KNOWN_INCONCLUSIVE is a NEW inconclusive and fails the gate.
record_incon() { # $1 = shader name, $2 = reason
  incon=$((incon+1))
  if is_known_incon "$1"; then
    incon_seen="$incon_seen $1"
    echo "INCONCLUSIVE $1 ($2)  [known/ratcheted]"
  else
    incon_regression=$((incon_regression+1))
    echo "INCONCLUSIVE $1 ($2)  *** NEW INCONCLUSIVE: not in KNOWN_INCONCLUSIVE ***"
  fi
}
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
  #    INCONCLUSIVE means OUR output is invalid AND the reference cannot be built, so
  #    NEITHER leg can judge the case. That is not a pass: ungated, it is a free pass
  #    an invalid output can hide behind (#690; the HLSL twin of this gate let 12
  #    glslang-invalid outputs survive exactly this way until PR #680 tripped over
  #    them). So the class is ratcheted: a shader landing on either branch below that
  #    is not in this stage's KNOWN_INCONCLUSIVE list is a NEW unjudgeable case and
  #    FAILS the gate (the set may only shrink). This ratchets ONLY the
  #    reference-unbuildable class; metal-limit is counted separately and stays
  #    non-gating.
  if ! glslangValidator -V -S "$GSTAGE" "$f" -o "$TMP/r.spv" >/dev/null 2>&1; then
    record_incon "$name" "SPIR-V build failed"; continue
  fi
  if ! spirv-cross "$TMP/r.spv" --msl > "$TMP/ref.metal" 2>/dev/null; then
    record_incon "$name" "spirv-cross failed"; continue
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
# Stale-entry hygiene (#690): a listed shader that did not land in the class this run
# is fixed or environment drift. Prune it so the list stays the CURRENT set; a
# ratchet listing non-members is a ratchet nobody reads (the disease #688 pruned).
for k in $KNOWN_INCONCLUSIVE; do
  case " $incon_seen " in *" $k "*) ;; *) echo "NOTE: KNOWN_INCONCLUSIVE entry $k was not inconclusive this run -- prune it from the $STAGE list.";; esac
done
echo
echo "MSL (spirv-cross-discriminated):"
echo "  valid=$valid  INVALID(real-bug)=$invalid  metal-limit=$mlim  inconclusive=$incon (new=$incon_regression)  honest-error=$herr  / $total"
echo "Gate signal is INVALID (real-bug: spirv-cross ref compiles but zioshade fails) plus no NEW INCONCLUSIVE (ratchet, #690)."
[ "$invalid" -eq 0 ] && [ "$incon_regression" -eq 0 ]
