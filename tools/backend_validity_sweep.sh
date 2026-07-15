#!/usr/bin/env bash
# Backend validity sweep: cross-compile every shader in a corpus to each target
# backend and validate the output with that ecosystem's reference tool. This is
# the "does the emitted source actually compile" gate, complementing the on-GPU
# numeric differential in tools/compute_diff.sh (which proves MSL correctness) and
# the SPIR-V corpus sweep in tools/corpus_sweep.sh (which proves frontend validity).
#
#   GLSL  -> glslangValidator   (always, if present)
#   WGSL  -> naga               (skipped if naga is not installed)
#   MSL   -> covered on-GPU by tools/compute_diff.sh (not re-validated here)
#
# A backend that emits source its own validator rejects is the exact silent-wrong
# class this project exists to prevent, so any rejection fails the sweep.
#
# Usage: tools/backend_validity_sweep.sh [dir] [stage] [ext]
#   dir    corpus directory   (default: tools/compute_corpus)
#   stage  shader stage       (default: compute)
#   ext    file extension     (default: comp)
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tools/compute_corpus}
STAGE=${2:-compute}
EXT=${3:-comp}
CLI=${CLI:-zig-out/bin/zioshade}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
HAVE_NAGA=0; command -v naga >/dev/null && HAVE_NAGA=1

# glslangValidator wants a stage flag matching the shader stage.
case "$STAGE" in
  compute) GV_STAGE=comp;; fragment) GV_STAGE=frag;; vertex) GV_STAGE=vert;;
  *) GV_STAGE=$EXT;;
esac

glsl_ok=0 glsl_bad=0 wgsl_ok=0 wgsl_bad=0 wgsl_skip=0 total=0
printf "%-26s %-14s %-14s\n" "shader" "GLSL" "WGSL"
printf -- "-%.0s" {1..56}; echo

for f in "$DIR"/*."$EXT"; do
  [ -e "$f" ] || continue
  total=$((total+1))
  name=$(basename "$f")

  # GLSL
  gstat="ERR"
  if "$CLI" glsl "$f" --stage "$STAGE" > "$TMP/o.glsl" 2>/dev/null; then
    if glslangValidator -S "$GV_STAGE" "$TMP/o.glsl" >/dev/null 2>&1; then gstat="valid"; glsl_ok=$((glsl_ok+1)); else gstat="INVALID"; glsl_bad=$((glsl_bad+1)); fi
  else gstat="ERR-EMIT"; glsl_bad=$((glsl_bad+1)); fi

  # WGSL
  wstat="skip(no naga)"
  if [ "$HAVE_NAGA" = 1 ]; then
    if "$CLI" wgsl "$f" --stage "$STAGE" > "$TMP/o.wgsl" 2>/dev/null; then
      if naga "$TMP/o.wgsl" >/dev/null 2>&1; then wstat="valid"; wgsl_ok=$((wgsl_ok+1)); else wstat="INVALID"; wgsl_bad=$((wgsl_bad+1)); fi
    else wstat="ERR-EMIT"; wgsl_bad=$((wgsl_bad+1)); fi
  else wgsl_skip=$((wgsl_skip+1)); fi

  printf "%-26s %-14s %-14s\n" "$name" "$gstat" "$wstat"
done

echo
echo "GLSL: valid=$glsl_ok invalid=$glsl_bad / $total"
if [ "$HAVE_NAGA" = 1 ]; then echo "WGSL: valid=$wgsl_ok invalid=$wgsl_bad / $total"; else echo "WGSL: skipped ($wgsl_skip, naga not installed)"; fi
[ "$glsl_bad" -eq 0 ] && [ "$wgsl_bad" -eq 0 ]
