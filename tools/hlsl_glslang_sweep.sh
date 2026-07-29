#!/usr/bin/env bash
# HLSL backend-validity sweep (INTERIM tier-1 gate): cross-compile every shader in a
# corpus to HLSL and check the output with glslangValidator's HLSL frontend. This is
# the always-on, no-infra analog of tools/hlsl_validity_sweep.sh (HLSL -> DXC).
#
# IMPORTANT — this is an INTERIM, NON-CANONICAL gate:
#   * glslang's HLSL frontend is a Khronos-authored parser, NOT the authoritative HLSL
#     compiler (DXC/fxc is). It reliably catches the classes that matter for an emitter
#     gate on SM5-era shaders (syntax errors, undeclared identifiers, type mismatches,
#     broken SV_ stage I/O, sampler-type errors) and its false-fails err in the SAFE
#     (honest-error) direction, but it false-passes some deep semantic errors DXC catches
#     and lacks later SM6.x features. See KhronosGroup/glslang#4210 (open RFC to remove
#     the HLSL frontend). Pin the glslang version when relying on this gate.
#   * The CANONICAL tier-2 gate is `hlsl-dxc` (DXC in Docker). It stays the gold standard
#     and should be wired in the moment Docker/DXC infra is available; it is NOT replaced
#     by this gate.
#
# To avoid the known false-fail trap (glslang rejecting valid-but-advanced HLSL that is a
# glslang limitation, NOT a zioshade bug), every glslang rejection is DISCRIMINATED
# against the spirv-cross reference oracle: the same shader cross-compiled by spirv-cross
# to HLSL is also checked. Only if spirv-cross's HLSL PASSES glslang while zioshade's
# FAILS is it counted as a REAL zioshade bug (the gate signal).
#
# Classification:
#   valid          = glslangValidator accepts zioshade's HLSL
#   INVALID        = REAL bug: spirv-cross reference HLSL passes glslang but zioshade's
#                    fails (gate signal; exits nonzero)
#   glslang-limit  = both zioshade and spirv-cross HLSL fail glslang — a glslang HLSL
#                    frontend limitation, NOT a zioshade bug (counted, not fatal)
#   inconclusive   = the spirv-cross reference could not be built (SPIR-V build or
#                    spirv-cross failed) so the case can't be classified
#   oracle-crash   = glslangValidator segfaulted (exit > 128) — the oracle is unstable
#                    here; counted separately, not fatal
#   honest-error   = zioshade frontend refused (Unsupported*) — no HLSL emitted
#
# Usage: tools/hlsl_glslang_sweep.sh [dir] [stage] [ext]
#   dir    corpus directory   (default: tests/spirv-cross)
#   stage  shader stage       (default: fragment)
#   ext    file extension     (default: frag)
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tests/spirv-cross}
STAGE=${2:-fragment}
EXT=${3:-frag}
CLI=${CLI:-zig-out/bin/zioshade}

case "$STAGE" in
  fragment) HSTAGE=frag;;
  vertex)   HSTAGE=vert;;
  compute)  HSTAGE=comp;;
  *)        HSTAGE="$STAGE";;
esac

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
command -v spirv-cross >/dev/null       || { echo "error: spirv-cross not on PATH (needed for the reference discriminator)"; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# glslang HLSL validation: -D selects HLSL input, -V forces parse+SPIR-V-codegen (a bare
# HLSL parse is rejected with "HLSL requires SPIR-V code generation"), -e main matches
# zioshade's entry point. Returns: 0=accept, >128=crash, else=reject.
hlsl_check() { # $1 = file  -> echoes "ok"|"crash"|"bad"
  glslangValidator -D -V -S "$HSTAGE" -e main "$1" >/dev/null 2>&1
  local gc=$?
  if [ $gc -eq 0 ]; then echo ok
  elif [ "$gc" -gt 128 ]; then echo crash
  else echo bad; fi
}

valid=0 invalid=0 glim=0 incon=0 ocrash=0 herr=0 total=0 regression=0

# KNOWN-DEFERRED real bugs: triaged, root-caused, and explicitly deferred (core
# machinery / structural work the 5-voice panel deferred to the canonical DXC gate).
# An INVALID that is NOT in this set is a NEW regression and the actionable signal.
# Stage-aware: each stage has its own deferred baseline. Keep in sync with the zioshade
# memory HLSL section. Run all stages: `just hlsl-glslang-all`.
case "$STAGE" in
  fragment)
    # No known HLSL fragment INVALIDs. false-loop-init.frag (#491 selection-merge-phi
    # hoist) and partial-write-preserve.frag (inout struct member write) WERE here but are
    # FIXED by #483 and #484 respectively; for-loop-init.frag by #482. Merge #482, #483,
    # #484 before this for a green gate (else the empty baseline re-flags whichever is
    # still unfixed on main).
    KNOWN_INVALID=" ";;
  vertex)
    # No known HLSL vertex INVALIDs. read-from-row-major-array.vert fixed (#489:
    # multi-dim UBO array dims + row_major drilling). out-block-qualifiers.vert now
    # honest-errors (#491: colliding output block members can't flatten without
    # duplicate VS_OUTPUT fields; full member-name-prefixing/block-reconstruction
    # deferred).
    KNOWN_INVALID=" ";;
  compute)
    # spec-constant-op-member-array.vk.comp WAS here (OpSpecConstantOp-sized array
    # member dropped its dim -> scalar). Fixed: the analyzer already bound user_name
    # on the spec_constant_ops entry; codegen now looks it up by user_name (not the
    # synthetic map key) and emits OpTypeArray, and the HLSL backend evaluates the
    # OpSpecConstantOp (IAdd/ISub/IMul of operand defaults) to a concrete size.
    KNOWN_INVALID=" cfg.comp ";;
  *)
    KNOWN_INVALID=" ";;
esac
is_known() { case " $KNOWN_INVALID " in *" $1 "*) return 0;; *) return 1;; esac; }

for f in "$DIR"/*."$EXT"; do
  [ -e "$f" ] || continue
  case "$f" in *.asm.*) continue;; esac   # SPIR-V assembly, not GLSL source
  total=$((total+1))
  name=$(basename "$f")

  # 1. zioshade emits HLSL (frontend refusal = honest-error).
  if ! "$CLI" hlsl "$f" --stage "$STAGE" > "$TMP/z.hlsl" 2>/dev/null; then
    herr=$((herr+1)); continue
  fi

  # 2. glslang checks zioshade's HLSL.
  zc=$(hlsl_check "$TMP/z.hlsl")
  if [ "$zc" = ok ]; then valid=$((valid+1)); continue; fi
  if [ "$zc" = crash ]; then ocrash=$((ocrash+1)); echo "ORACLE-CRASH $name"; continue; fi

  # 3. zioshade failed glslang -> discriminate against the spirv-cross reference.
  #    Build SPIR-V from the GLSL source, cross it to HLSL, check the reference.
  if ! glslangValidator -V -S "$HSTAGE" "$f" -o "$TMP/r.spv" >/dev/null 2>&1; then
    incon=$((incon+1)); echo "INCONCLUSIVE $name (SPIR-V build failed)"; continue
  fi
  if ! spirv-cross "$TMP/r.spv" --hlsl --shader-model 50 > "$TMP/ref.hlsl" 2>/dev/null; then
    incon=$((incon+1)); echo "INCONCLUSIVE $name (spirv-cross failed)"; continue
  fi
  rc=$(hlsl_check "$TMP/ref.hlsl")
  if [ "$rc" = ok ]; then
    # Reference PASSES, zioshade FAILS -> real zioshade bug (the gate signal).
    invalid=$((invalid+1))
    if is_known "$name"; then
      echo "INVALID $name  [known/deferred]"
    else
      regression=$((regression+1)); echo "INVALID $name  *** NEW REGRESSION ***"
    fi
  else
    # Both fail -> glslang HLSL frontend limitation, not zioshade's fault.
    glim=$((glim+1)); echo "GLSLANG-LIMIT $name"
  fi
done

echo
echo "HLSL (interim glslang gate, spirv-cross-discriminated):"
echo "  valid=$valid  INVALID(real-bug)=$invalid (regression=$regression)  glslang-limit=$glim  inconclusive=$incon  oracle-crash=$ocrash  honest-error=$herr  / $total"
echo "Gate signal is REGRESSION (an INVALID not in the known-deferred set)."
[ "$regression" -eq 0 ]
