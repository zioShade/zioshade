#!/usr/bin/env bash
# zioshade - test-case reduction via spirv-reduce (r2d.6)
#
# Minimizes a SPIR-V input that triggers a zioshade cross-compiler bug (a crash, or
# output a backend oracle rejects) to a minimal repro, using Khronos spirv-reduce.
# Closes the "no test-case reduction" methodology gap from the maturity assessment:
# when the fuzzer or a prove/render hit surfaces a failing shader, this turns a large
# module into a small one for the bug report / fix.
#
# The bug must reproduce on the SPIR-V INPUT -- i.e. a cross-compiler BACKEND / optimizer
# bug where zioshade CONSUMES the .spv. (Frontend GLSL->SPIR-V bugs need a GLSL reducer,
# glsl-reduce, not this tool -- spirv-reduce only reduces SPIR-V.) zioshade's backend
# subcommands accept a .spv directly with --stage.
#
# Usage:
#   tools/reduce.sh <input.spv> <mode> [mode-arg] [--step-limit N] [--target-function ID]
#   modes:
#     crash-msl | crash-glsl | crash-hlsl | crash-wgsl   zioshade <backend> on the candidate exits nonzero
#     reject-glsl                                         zioshade glsl output is REJECTED by glslangValidator
#     reject-wgsl                                         zioshade wgsl output is REJECTED by naga
#     custom <script>                                     <script> is an executable interestingness test
#                                                        (takes the candidate .spv path; exit 0 = interesting)
#   env: STAGE=fragment|vertex|compute (default fragment); OUT=reduced.spv
#
# Examples:
#   tools/reduce.sh failing.spv crash-msl
#   tools/reduce.sh failing.spv reject-wgsl --step-limit=200
#   tools/reduce.sh failing.spv custom ./my-interestingness.sh
# (spirv-reduce options use the = form: --step-limit=N, --target-function=ID, not "--step-limit N")
set -euo pipefail
export PATH="$HOME/.local/share/mise/shims:$PATH"
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v spirv-reduce >/dev/null  || { echo "error: spirv-reduce not on PATH (spirv-tools)"; exit 2; }
command -v spirv-dis   >/dev/null   || { echo "error: spirv-dis not on PATH (spirv-tools)"; exit 2; }

[ $# -ge 2 ] || { sed -n '2,33p' "$0" >&2; exit 2; }
IN="$1"; MODE="$2"; shift 2
STAGE=${STAGE:-fragment}
OUT=${OUT:-reduced.spv}
CUSTOM=""

[ -f "$IN" ] || { echo "error: input not found: $IN"; exit 2; }
spirv-val "$IN" >/dev/null 2>&1 || { echo "error: input is not valid SPIR-V (spirv-reduce requires a valid module): $IN"; exit 2; }

# Build the interestingness script for the chosen mode. It takes the candidate .spv as $1
# and exits 0 iff the candidate is still "interesting" (still triggers the bug).
INT=$(mktemp); trap 'rm -f "$INT" "$OUT.z.glsl" "$OUT.z.wgsl"' EXIT
WHAT=""
case "$MODE" in
  crash-msl|crash-glsl|crash-hlsl|crash-wgsl)
    BACKEND=${MODE#crash-}
    cat > "$INT" <<EOF
#!/usr/bin/env bash
export PATH="$HOME/.local/share/mise/shims:\$PATH"
"$CLI" $BACKEND "\$1" --stage $STAGE >/dev/null 2>&1
exit \$(( \$? == 0 ? 1 : 0 ))   # zioshade nonzero (crash / honest-error) = interesting
EOF
    WHAT="zioshade $BACKEND exits nonzero on the candidate" ;;
  reject-glsl)
    command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
    cat > "$INT" <<EOF
#!/usr/bin/env bash
export PATH="$HOME/.local/share/mise/shims:\$PATH"
"$CLI" glsl "\$1" --stage $STAGE > "\$1.z.glsl" 2>/dev/null || exit 1   # zioshade failed -> not interesting
glslangValidator -V -S $STAGE "\$1.z.glsl" >/dev/null 2>&1 && exit 1   # glslang accepted -> not interesting
rm -f "\$1.z.glsl"; exit 0                                            # zioshade OK + glslang rejected = interesting
EOF
    WHAT="zioshade glsl output is rejected by glslangValidator" ;;
  reject-wgsl)
    command -v naga >/dev/null || { echo "error: naga not on PATH"; exit 2; }
    cat > "$INT" <<EOF
#!/usr/bin/env bash
export PATH="$HOME/.local/share/mise/shims:\$PATH"
"$CLI" wgsl "\$1" --stage $STAGE > "\$1.z.wgsl" 2>/dev/null || exit 1
naga "\$1.z.wgsl" >/dev/null 2>&1 && exit 1
rm -f "\$1.z.wgsl"; exit 0
EOF
    WHAT="zioshade wgsl output is rejected by naga" ;;
  custom)
    [ $# -ge 1 ] || { echo "error: 'custom' mode needs an interestingness-script path"; exit 2; }
    CUSTOM="$1"; shift
    [ -x "$CUSTOM" ] || { echo "error: interestingness script not executable: $CUSTOM"; exit 2; }
    INT="$(cd "$(dirname "$CUSTOM")" && pwd)/$(basename "$CUSTOM")"   # absolute; trap won't rm it
    trap - EXIT
    WHAT="custom interestingness: $INT" ;;
  *) echo "error: unknown mode '$MODE' (see header)"; exit 2 ;;
esac
[ "$MODE" != "custom" ] && chmod +x "$INT"

# Sanity: confirm the INPUT is interesting before reducing; otherwise nothing to reduce.
if ! "$INT" "$IN" >/dev/null 2>&1; then
  echo "note: the input is NOT interesting under '$MODE' ($WHAT)."
  echo "      The bug may already be fixed, or this mode does not reproduce it. Nothing to reduce."
  exit 1
fi

echo "reducing $IN; interestingness = $WHAT"
spirv-reduce --temp-file-prefix="/tmp/zioshade_reduce_" "$@" "$IN" -o "$OUT" -- "$INT" > "${OUT%.spv}.reduce.log" 2>&1 \
  || { echo "error: spirv-reduce failed (last lines of ${OUT%.spv}.reduce.log):"; tail -8 "${OUT%.spv}.reduce.log" >&2; exit 1; }
spirv-dis "$OUT" > "${OUT%.spv}.asm"

osize=$(wc -c < "$IN" | tr -d ' '); rsize=$(wc -c < "$OUT" | tr -d ' ')
iinstr=$(spirv-dis "$IN" 2>/dev/null | grep -cE '^[[:space:]]*[%A-Za-z]' || true)
rinstr=$(spirv-dis "$OUT" 2>/dev/null | grep -cE '^[[:space:]]*[%A-Za-z]' || true)
echo ""
echo "reduced: $IN -> $OUT"
echo "  bytes:       $osize -> $rsize"
echo "  instr lines: $iinstr -> $rinstr"
echo "  disassembly: ${OUT%.spv}.asm"
if "$INT" "$OUT" >/dev/null 2>&1; then echo "  still interesting: yes"; else echo "  still interesting: NO -- reduction broke the repro (try --fail-on-validation-error)"; fi
