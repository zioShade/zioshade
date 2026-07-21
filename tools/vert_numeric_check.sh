#!/usr/bin/env bash
# Numeric vertex differential (tools/VertexNumeric.swift): captures each vertex's computed
# gl_Position into a buffer and diffs numerically, so EVERY vertex shader gets coverage
# regardless of where its gl_Position lands (unlike the rasterising vert_render_check.sh,
# which only has test power for on-screen triangles).
#
#   FRONTEND oracle: zioshade-frontend SPIR-V vs glslang SPIR-V, both --(spirv-cross)--> MSL
#   BACKEND check:   zioshade-own MSL backend vs glslang -> spirv-cross MSL
# Verdicts: MATCH | DIFFER(frontend=MISCOMPILE) | DIFFER(frontend-clean,backend) | skip-*
set -u
CLI=./zig-out/bin/zioshade
SHARE=/private/tmp/claude-501/-Users-alex-claude/2e7ff35b-0e04-4cb1-9600-f56f35b3f7b7/scratchpad/vtx
VN=$SHARE/VertexNumeric
mkdir -p "$SHARE"
[ -x "$VN" ] || swiftc tools/VertexNumeric.swift -o "$VN" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }
SCFLAGS="--msl-version 20100"

check_one() {
  local vert="$1" name; name=$(basename "$vert" .vert)
  local zspv="$SHARE/$name.z.spv" zfe="$SHARE/$name.zfe.msl"
  local gspv="$SHARE/$name.g.spv" gm="$SHARE/$name.g.msl" zb="$SHARE/$name.zb.msl"
  "$CLI" compile "$vert" --stage vertex -o "$zspv" 2>/dev/null || { echo "skip-zioshade-compile"; return; }
  spirv-cross --msl $SCFLAGS "$zspv" > "$zfe" 2>/dev/null || { echo "skip-crossmsl-zio"; return; }
  glslangValidator -V --amb --aml -S vert "$vert" -o "$gspv" >/dev/null 2>&1 || { echo "skip-glslang"; return; }
  spirv-cross --msl $SCFLAGS "$gspv" > "$gm" 2>/dev/null || { echo "skip-crossmsl-ref"; return; }
  "$CLI" msl "$vert" --stage vertex > "$zb" 2>/dev/null || zb=""

  local fe; fe=$("$VN" "$zfe" "$gm" 2>/dev/null)
  case "$fe" in
    "") echo "skip-capture"; return;;
  esac
  printf '%s' "$fe" | grep -q '^SKIP' && { echo "skip-capture"; return; }
  local fev; fev=$(printf '%s' "$fe" | tail -1)
  local nz; nz=$(printf '%s' "$fe" | grep -oE 'nonzero=(yes|no)' | grep -oE '(yes|no)')
  local mr; mr=$(printf '%s' "$fe" | grep -oE 'maxRel=[0-9.eg+-]+' | head -1)
  if [ "$fev" = DIFFER ]; then echo "DIFFER(frontend=MISCOMPILE,$mr)"; return; fi
  if [ -n "$zb" ]; then
    local be; be=$("$VN" "$zb" "$gm" 2>/dev/null); local bev; bev=$(printf '%s' "$be" | tail -1)
    local bmr; bmr=$(printf '%s' "$be" | grep -oE 'maxRel=[0-9.eg+-]+' | head -1)
    if [ "$bev" = DIFFER ]; then echo "DIFFER(frontend-clean,backend,$bmr)"; return; fi
  fi
  if [ "$nz" = no ]; then echo "MATCH(trivial-zero)"; else echo "MATCH(covered)"; fi
}

if [ "${1:-}" = "--sweep" ]; then
  for v in tests/spirv-cross/*.vert; do case "$v" in *.asm.*) continue;; esac; echo "$(basename "$v"): $(check_one "$v")"; done
else
  check_one "$1"
fi
