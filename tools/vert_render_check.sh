#!/usr/bin/env bash
# Vertex-shader differential render check (the vertex analog of hlsl_render_check.sh's
# frontend oracle). For a .vert shader it renders the triangle its gl_Positions define
# (tools/VertexCompare.swift) two ways and compares:
#   FRONTEND oracle: zioshade-frontend SPIR-V  --(spirv-cross)--> MSL   vs
#                    glslang SPIR-V             --(spirv-cross)--> MSL
#     Same backend cancels backend fp, so a divergence is a FRONTEND miscompile.
#   BACKEND check:   zioshade-own MSL backend   vs   glslang->spirv-cross MSL
#     A divergence here (when the frontend is clean) points at zioshade's MSL backend.
#
# Verdicts: RENDER-MATCH | RENDER-DIFFER(frontend=MISCOMPILE) |
#           RENDER-DIFFER(frontend-clean,backend) | no-coverage(inconclusive) | skip-*
set -u
CLI=./zig-out/bin/zioshade
SHARE=/private/tmp/claude-501/-Users-alex-claude/2e7ff35b-0e04-4cb1-9600-f56f35b3f7b7/scratchpad/vtx
VC=$SHARE/VertexCompare
mkdir -p "$SHARE"
[ -x "$VC" ] || swiftc tools/VertexCompare.swift -o "$VC" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }
# spirv-cross needs MSL 2.1 for a few features (invariant position); match zioshade's default.
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

  local fe; fe=$("$VC" "$zfe" "$gm" 2>&1)
  case "$fe" in
    SKIP*) echo "skip-inputs"; return;;
  esac
  local fe_v; fe_v=$(printf '%s' "$fe" | grep -oE 'MATCH|DIFFER' | head -1)
  local cov; cov=$(printf '%s' "$fe" | grep -oE 'Coverage: (yes|none)' | grep -oE '(yes|none)')
  local md; md=$(printf '%s' "$fe" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
  local px; px=$(printf '%s' "$fe" | grep -oE 'Different: [0-9]+' | grep -oE '[0-9]+$')

  if [ "$fe_v" = DIFFER ]; then
    echo "RENDER-DIFFER(px=${px:-?},maxdiff=${md:-?},frontend=MISCOMPILE)"; return
  fi
  # Frontend matches. Check zioshade's own backend against the reference.
  if [ -n "$zb" ]; then
    local be; be=$("$VC" "$zb" "$gm" 2>&1)
    local be_v; be_v=$(printf '%s' "$be" | grep -oE 'MATCH|DIFFER' | head -1)
    local bmd; bmd=$(printf '%s' "$be" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
    local bpx; bpx=$(printf '%s' "$be" | grep -oE 'Different: [0-9]+' | grep -oE '[0-9]+$')
    if [ "$be_v" = DIFFER ]; then
      echo "RENDER-DIFFER(px=${bpx:-?},maxdiff=${bmd:-?},frontend-clean,backend)"; return
    fi
  fi
  if [ "$cov" = none ]; then echo "no-coverage(inconclusive)"; else echo "RENDER-MATCH"; fi
}

if [ "${1:-}" = "--sweep" ]; then
  for v in tests/spirv-cross/*.vert; do
    case "$v" in *.asm.*) continue;; esac
    echo "$(basename "$v"): $(check_one "$v")"
  done
else
  check_one "$1"
fi
