#!/usr/bin/env bash
# GLSL backend-validity sweep: cross-compile every shader in a corpus to GLSL
# and compile-check the output with glslangValidator (real GLSL oracle). This is
# the GLSL analog of tools/msl_validity_sweep.sh (MSL->Metal) and
# tools/wgsl_naga_sweep.sh (WGSL->naga): a real backend-validity gate that
# catches the silent-wrong class (emit valid-looking GLSL at exit 0 that
# glslangValidator rejects).
#
# Validation modes:
#   * Vulkan:  `glslangValidator -V -S frag` (Vulkan SPIR-V target — the stricter mode;
#                  requires explicit locations, Vulkan-flavored GLSL)
#   * Desktop: `glslangValidator -S frag`    (desktop OpenGL — the permissive mode;
#                  zioshade's default #version 430 is desktop GLSL)
# A shader is VALID if EITHER mode compiles (both modes are tried for every shader).
# spec-const shaders (layout(constant_id)) are Vulkan-only and pass -V.
#
# DISCRIMINATION (spirv-cross reference): every glslang rejection is checked against
# the spirv-cross reference — the same source cross-compiled by spirv-cross to GLSL.
# Only if spirv-cross's GLSL PASSES glslang while zioshade's FAILS is it counted as a
# REAL zioshade bug (the gate signal). If both fail, it is a glslang limitation
# (broken source, unsupported extension, etc.) — NOT a zioshade bug — and counted
# separately, not as INVALID. This mirrors tools/hlsl_glslang_sweep.sh and keeps the
# gate honest (no chasing glslang-limits as if they were emitter bugs).
#
# Classification:
#   valid          = glslangValidator accepts zioshade's GLSL (either mode)
#   INVALID        = REAL bug: spirv-cross reference GLSL passes but zioshade's fails
#   glslang-limit  = both zioshade and spirv-cross GLSL fail glslang — a glslang/source
#                    limitation, NOT a zioshade bug (counted, not fatal)
#   inconclusive   = the spirv-cross reference could not be built (SPIR-V build or
#                    spirv-cross failed) so the case can't be classified. RATCHETED
#                    (#690): an inconclusive case not in KNOWN_INCONCLUSIVE below
#                    fails the gate (see the comment at the discrimination step).
#   honest-error   = zioshade frontend refused — no GLSL emitted
#
# Requires: a built CLI (zig build cli), glslangValidator + spirv-cross on PATH.
#
# Usage: tools/glsl_glslang_sweep.sh [dir] [stage] [ext]
#   dir    corpus directory   (default: tests/spirv-cross)
#   stage  shader stage       (default: fragment)
#   ext    file extension     (default: frag)
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tests/spirv-cross}
STAGE=${2:-fragment}
EXT=${3:-frag}
CLI=${CLI:-zig-out/bin/zioshade}

# glslangValidator needs the short stage name (frag/vert/...), not the long form.
case "$STAGE" in
  fragment) GSTAGE=frag;;
  vertex)   GSTAGE=vert;;
  compute)  GSTAGE=comp;;
  *)        GSTAGE="$STAGE";;
esac

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v spirv-cross >/dev/null       || { echo "error: spirv-cross not on PATH (needed for the reference discriminator)"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/o.$GSTAGE"

# glslang GLSL validation: Vulkan (-V) then desktop fallback. Returns 0=accept, 1=reject.
glsl_check() { # $1 = file  -> echo ok|bad
  if glslangValidator -V -S "$GSTAGE" "$1" >/dev/null 2>&1 \
     || glslangValidator -S "$GSTAGE" "$1" >/dev/null 2>&1; then
    echo ok
  else
    echo bad
  fi
}

valid=0 invalid=0 glim=0 incon=0 herr=0 total=0 regression=0 incon_regression=0

# KNOWN-DEFERRED real bugs: triaged, root-caused, explicitly deferred. An INVALID NOT in
# this set is a NEW regression and the actionable signal. Stage-aware; mirrors
# tools/hlsl_glslang_sweep.sh. Keep in sync with the zioshade memory GLSL section.
# NOTE: vertex/compute baselines are intentionally empty -- the fragment-only blind spot
# (~29 unchecked GLSL vertex+compute INVALIDs, found 2026-07-25) is a separate triage
# effort; until then `glsl-glslang-all` is expected to flag them. Fragment is the gate.
case "$STAGE" in
  fragment)
    # No known GLSL fragment INVALIDs currently. for-loop-init.frag WAS here (a loop-carried
    # counter-load scope bug from #loop-continue-deadincr) but is FIXED by #482 -- empty now.
    # Merge #482 before this for a green gate.
    KNOWN_INVALID=" ";;
  *)
    KNOWN_INVALID=" ";;
esac
is_known() { case " $KNOWN_INVALID " in *" $1 "*) return 0;; *) return 1;; esac; }

# KNOWN_INCONCLUSIVE ratchet (#690): the CURRENT per-stage set of shaders whose
# spirv-cross reference cannot be built, so neither leg can judge them. See the
# comment at the discrimination step below for why this class must not be a free
# pass. An INCONCLUSIVE not in this stage's list is a NEW unjudgeable case and
# FAILS the gate; the set may only shrink, and an entry that no longer lands in
# the class prints a prune note after the run. Keep per-stage, like KNOWN_INVALID.
case "$STAGE" in
  fragment)
    KNOWN_INCONCLUSIVE=" switch_loop.frag";;
  vertex)
    # No INCONCLUSIVE GLSL vertex cases currently.
    KNOWN_INCONCLUSIVE=" ";;
  compute)
    KNOWN_INCONCLUSIVE=" fp-atomic.nocompat.vk.comp reduce_sum.comp subgroup_elect.comp";;
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

  # 1. zioshade emits GLSL (frontend refusal = honest-error).
  if ! "$CLI" glsl "$f" --stage "$STAGE" -o "$OUT" 2>/dev/null; then
    herr=$((herr+1)); continue
  fi

  # 2. glslang checks zioshade's GLSL.
  if [ "$(glsl_check "$OUT")" = ok ]; then
    valid=$((valid+1)); continue
  fi

  # 3. zioshade failed glslang -> discriminate against the spirv-cross reference.
  #    Build SPIR-V from the GLSL source, cross it to GLSL, check the reference.
  #    INCONCLUSIVE means OUR output is invalid AND the reference cannot be built, so
  #    NEITHER leg can judge the case. That is not a pass: ungated, it is a free pass
  #    an invalid output can hide behind (#690; the HLSL twin of this gate let 12
  #    glslang-invalid outputs survive exactly this way until PR #680 tripped over
  #    them). So the class is ratcheted: a shader landing on either branch below that
  #    is not in this stage's KNOWN_INCONCLUSIVE list is a NEW unjudgeable case and
  #    FAILS the gate (the set may only shrink). This ratchets ONLY the
  #    reference-unbuildable class; glslang-limit is counted separately and stays
  #    non-gating.
  if ! glslangValidator -V -S "$GSTAGE" "$f" -o "$TMP/r.spv" >/dev/null 2>&1; then
    record_incon "$name" "SPIR-V build failed"; continue
  fi
  if ! spirv-cross "$TMP/r.spv" > "$TMP/ref.glsl" 2>/dev/null; then
    record_incon "$name" "spirv-cross failed"; continue
  fi
  if [ "$(glsl_check "$TMP/ref.glsl")" = ok ]; then
    # Reference PASSES, zioshade FAILS -> real zioshade bug (the gate signal).
    invalid=$((invalid+1))
    if is_known "$name"; then
      echo "INVALID $name  [known/deferred]"
    else
      regression=$((regression+1)); echo "INVALID $name  *** NEW REGRESSION ***"
    fi
  else
    # Both fail -> glslang/source limitation, not zioshade's fault.
    glim=$((glim+1)); echo "GLSLANG-LIMIT $name"
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
echo "GLSL (spirv-cross-discriminated):"
echo "  valid=$valid  INVALID(real-bug)=$invalid (regression=$regression)  glslang-limit=$glim  inconclusive=$incon (new=$incon_regression)  honest-error=$herr  / $total"
echo "Gate signal is REGRESSION (an INVALID not in the known-deferred set) plus no NEW INCONCLUSIVE (ratchet, #690)."
[ "$regression" -eq 0 ] && [ "$incon_regression" -eq 0 ]
