#!/usr/bin/env bash
# Differential corpus sweep: run every GLSL shader in a directory through the
# zioshade CLI and categorize the outcome against the Khronos SPIR-V validator.
#
# This is the "does it behave like the tools it replaces" evidence: over a large
# body of shaders written for glslang / SPIRV-Cross, zioshade must either produce
# VALID SPIR-V or fail LOUD. The two categories that must be zero are:
#   - SILENT-WRONG: exit 0 but spirv-val rejects the output (the thing this
#     project exists to eliminate).
#   - CRASH: a panic / signal instead of a clean error.
#
# Usage:
#   tools/corpus_sweep.sh [dir] [stage] [ext]
#     dir    directory of shaders          (default: tests/spirv-cross)
#     stage  shader stage passed to the CLI (default: fragment)
#     ext    file extension to sweep        (default: frag)
#
# Requires: a built CLI at zig-out/bin/zioshade and spirv-val on PATH.
# SPIR-V *assembly* inputs (files matching *.asm.*) are skipped: they are not
# GLSL and belong to the cross-compiler's assembly path, not the GLSL frontend.
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tests/spirv-cross}
STAGE=${2:-fragment}
EXT=${3:-frag}
CLI=${CLI:-zig-out/bin/zioshade}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli); not found at $CLI" >&2; exit 2; }
command -v spirv-val >/dev/null || { echo "error: spirv-val not on PATH" >&2; exit 2; }

ok=0 herr=0 wrong=0 crash=0 total=0
: > "$TMP/wrong.txt"; : > "$TMP/crash.txt"

for f in "$DIR"/*."$EXT"; do
  [ -e "$f" ] || continue
  case "$f" in *.asm.*) continue;; esac  # SPIR-V assembly, not GLSL
  total=$((total+1))
  "$CLI" compile "$f" --stage "$STAGE" -o "$TMP/out.spv" 2>"$TMP/err.txt"
  code=$?
  if [ $code -eq 0 ]; then
    if spirv-val "$TMP/out.spv" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      wrong=$((wrong+1)); echo "$f" >> "$TMP/wrong.txt"
    fi
  elif [ $code -gt 128 ] || grep -qiE "panic|reached unreachable|segmentation" "$TMP/err.txt"; then
    crash=$((crash+1)); echo "$f" >> "$TMP/crash.txt"
  else
    herr=$((herr+1))
  fi
done

echo "corpus:            $DIR/*.$EXT  (stage=$STAGE)"
echo "total (GLSL):      $total"
echo "valid SPIR-V:      $ok"
echo "honest-error:      $herr"
echo "SILENT-WRONG:      $wrong"
echo "CRASH:             $crash"
[ "$wrong" -gt 0 ] && { echo "--- silent-wrong files ---"; cat "$TMP/wrong.txt"; }
[ "$crash" -gt 0 ] && { echo "--- crash files ---"; cat "$TMP/crash.txt"; }

# The trust gate: any silent-wrong or crash is a failure.
[ "$wrong" -eq 0 ] && [ "$crash" -eq 0 ]
