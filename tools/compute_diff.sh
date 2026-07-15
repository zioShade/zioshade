#!/usr/bin/env bash
# Generic Metal COMPUTE differential proof.
#
# For every GLSL compute shader in a directory, produce MSL two ways:
#   A) zioshade    : GLSL -> MSL (direct)
#   B) reference   : GLSL -> SPIR-V (glslang) -> MSL (SPIRV-Cross)
# then run BOTH kernels on the Metal GPU over an identical input buffer and diff
# the output buffers (tools/ShaderComputeCompare.swift). A shader passes only if
# the numeric outputs match within tolerance.
#
# This is the compute analogue of the fragment-shader pixel diff in
# docs/DIFFERENTIAL_PROOF.md section 2: it proves zioshade's MSL backend
# computes the same values as SPIRV-Cross across the scalar/vector/matrix/
# intrinsic/control-flow surface, executed on real hardware.
#
# Usage: tools/compute_diff.sh [dir]   (default: tools/compute_corpus)
# Requires: built CLI, glslangValidator, spirv-cross, swiftc (macOS + Metal).
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tools/compute_corpus}
CLI=${CLI:-zig-out/bin/zioshade}
N=${N:-1024}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
for t in glslangValidator spirv-cross swiftc; do
  command -v "$t" >/dev/null || { echo "error: $t not on PATH"; exit 2; }
done

HARNESS="$TMP/ShaderComputeCompare"
echo "building harness..."
swiftc -O tools/ShaderComputeCompare.swift -o "$HARNESS" || { echo "error: harness build failed"; exit 2; }

pass=0 fail=0 err=0 total=0
printf "%-26s %-10s %-12s %s\n" "shader" "result" "maxRelDiff" "notes"
printf -- "-%.0s" {1..70}; echo

for f in "$DIR"/*.comp; do
  [ -e "$f" ] || continue
  total=$((total+1))
  name=$(basename "$f")

  # A) zioshade direct
  if ! "$CLI" msl "$f" --stage compute > "$TMP/a.msl" 2>"$TMP/a.err"; then
    printf "%-26s %-10s %-12s %s\n" "$name" "ERR-ZIO" "-" "$(head -1 "$TMP/a.err")"
    err=$((err+1)); continue
  fi
  # B) glslang -> spirv-cross
  if ! glslangValidator -V "$f" -S comp -o "$TMP/b.spv" >"$TMP/b.err" 2>&1; then
    printf "%-26s %-10s %-12s %s\n" "$name" "ERR-GLSLANG" "-" "$(tail -1 "$TMP/b.err")"
    err=$((err+1)); continue
  fi
  if ! spirv-cross --msl "$TMP/b.spv" > "$TMP/b.msl" 2>"$TMP/b.err"; then
    printf "%-26s %-10s %-12s %s\n" "$name" "ERR-CROSS" "-" "$(tail -1 "$TMP/b.err")"
    err=$((err+1)); continue
  fi

  out=$("$HARNESS" "$TMP/a.msl" "$TMP/b.msl" "$N" 2>&1)
  code=$?
  rel=$(echo "$out" | awk '/max rel diff:/{print $4}')
  nanmis=$(echo "$out" | awk '/NaN-mismatch:/{print $2}')
  if [ $code -eq 0 ]; then
    printf "%-26s %-10s %-12s %s\n" "$name" "MATCH" "${rel:-0}" "nanmis=${nanmis:-0}"
    pass=$((pass+1))
  else
    printf "%-26s %-10s %-12s %s\n" "$name" "DIFFER" "${rel:-?}" "$(echo "$out" | tail -1)"
    fail=$((fail+1))
    echo "$out" | sed 's/^/    /'
  fi
done

echo
echo "total: $total   match: $pass   differ: $fail   harness-error: $err"
[ "$fail" -eq 0 ] && [ "$err" -eq 0 ]
