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
# INVALID (both reject) = a real backend bug (the plausible-but-wrong class).
#
# Requires: a built CLI (zig build cli), glslangValidator on PATH.
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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/o.$GSTAGE"

# valid = glslangValidator accepts (either mode); INVALID = both modes reject
# (backend bug, the gate); herr = zioshade frontend refused (honest-error).
ok=0 bad=0 herr=0 total=0
fails=""
for f in "$DIR"/*."$EXT"; do
  [ -e "$f" ] || continue
  case "$f" in *.asm.*) continue;; esac   # SPIR-V assembly, not GLSL source
  total=$((total+1))
  name=$(basename "$f")
  if "$CLI" glsl "$f" --stage "$STAGE" -o "$OUT" 2>/dev/null; then
    # Try Vulkan mode first (stricter), then fall back to desktop. A shader is
    # VALID if EITHER mode compiles — zioshade's default #version 430 is desktop
    # GLSL, so desktop is a legitimate target for most shaders.
    if glslangValidator -V -S "$GSTAGE" "$OUT" >/dev/null 2>&1 \
       || glslangValidator -S "$GSTAGE" "$OUT" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      bad=$((bad+1)); fails="$fails $name"
      echo "INVALID $name"
    fi
  else
    herr=$((herr+1))
  fi
done

echo
echo "GLSL: valid=$ok  INVALID=$bad  honest-error=$herr  / $total"
[ "$bad" -eq 0 ]
