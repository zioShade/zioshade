#!/usr/bin/env bash
# MSL backend-validity sweep: cross-compile every shader in a corpus to MSL and
# compile-check the output with Metal (MTLDevice.makeLibrary via tools/MslCompileCheck.swift).
# This is the MSL analog of tools/backend_validity_sweep.sh (GLSL->glslangValidator,
# WGSL->naga): a real backend-validity oracle that catches the silent-wrong class
# (emit valid-looking MSL at exit 0 that the Metal compiler rejects).
#
# Requires: a built CLI (zig build cli), swiftc, and a Metal device (macOS).
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

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v swiftc >/dev/null || { echo "error: swiftc not on PATH"; exit 2; }
# Build the Metal compile-checker if missing or stale.
if [ ! -x "$CHECK" ] || [ tools/MslCompileCheck.swift -nt "$CHECK" ]; then
  swiftc -O tools/MslCompileCheck.swift -o "$CHECK" || { echo "error: failed to build MslCompileCheck"; exit 2; }
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# valid = Metal accepts; INVALID = Metal rejects (backend bug, the gate);
# herr = the zioshade frontend refused (honest-error, not a backend defect).
ok=0 bad=0 herr=0 total=0
for f in "$DIR"/*."$EXT"; do
  [ -e "$f" ] || continue
  case "$f" in *.asm.*) continue;; esac   # SPIR-V assembly, not GLSL source
  total=$((total+1))
  name=$(basename "$f")
  if "$CLI" msl "$f" --stage "$STAGE" > "$TMP/o.metal" 2>/dev/null; then
    if "$CHECK" "$TMP/o.metal" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      bad=$((bad+1)); echo "INVALID $name"
    fi
  else
    herr=$((herr+1))
  fi
done

echo
echo "MSL: valid=$ok  INVALID=$bad  honest-error=$herr  / $total"
[ "$bad" -eq 0 ]
