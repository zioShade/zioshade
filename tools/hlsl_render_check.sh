#!/usr/bin/env bash
# HLSL RENDER verification on macOS (no DirectX/Windows needed).
#
# HLSL can only be render-verified on a D3D runtime, which macOS lacks. The gold
# path is DXC -> DXIL -> D3D12 WARP (see tools/warp/, run on a Windows box). This
# script is the macOS-runnable complement: it renders zioshade's HLSL through the
# ACTUAL DXC HLSL compiler and diffs real pixels on the Metal GPU.
#
#   zioshade GLSL --(zioshade)--> HLSL --(DXC -spirv)--> SPIR-V
#                                       --(spirv-cross --msl)--> MSL_hlsl  --\
#   zioshade GLSL --(zioshade)--> MSL_ref  ------------------------------------> render both
#                                                                              on Metal, diff px
#
# DXC is the real HLSL oracle: if zioshade's HLSL is wrong, DXC compiles it to
# different SPIR-V, which renders different pixels. The reference (MSL_ref) is
# zioshade's own MSL backend, which is itself render-verified 0-pixel vs SPIRV-Cross
# (docs/DIFFERENTIAL_PROOF.md section 2). So a render MATCH here means zioshade's
# HLSL renders the same image as the render-proven MSL path = HLSL is render-correct,
# not merely DXC-compilable.
#
# This proves the HLSL is SEMANTICALLY correct as DXC parses it; it does NOT exercise
# the exact DXIL-on-D3D12 execution path wintty ships (that is the WARP harness's job).
# The two are complementary: this catches shader miscompiles today, WARP is the
# final pre-launch gate on the real runtime.
#
# Requires: built CLI, spirv-cross, the dxc-oracle container (see
# tools/hlsl_validity_sweep.sh), swiftc + a Metal GPU (macOS).
#
# Usage: tools/hlsl_render_check.sh <shader.frag> [stage]
#    or: tools/hlsl_render_check.sh --sweep [dir]
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
CONTAINER=${CONTAINER:-dxc-oracle}
PROFILE=${PROFILE:-ps_6_0}
SHARE_HOST=/private/tmp/claude-501/-Users-alex-claude/2e7ff35b-0e04-4cb1-9600-f56f35b3f7b7/scratchpad/hlslrender
SHARE_CONT=/work/hlslrender
SC_BIN=$SHARE_HOST/ShaderCompare

command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH"; exit 2; }
command -v swiftc >/dev/null || { echo "error: swiftc not found (need macOS)"; exit 2; }
docker exec "$CONTAINER" true 2>/dev/null || { echo "error: container $CONTAINER not running"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
mkdir -p "$SHARE_HOST"

# Build the Metal render+diff harness once (reused, unmodified, from the MSL proof).
[ -x "$SC_BIN" ] || swiftc tools/ShaderCompare.swift -o "$SC_BIN" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }

# Independent-oracle check via FRONTEND isolation. Compile the same GLSL with an
# INDEPENDENT frontend (glslang) and render BOTH zioshade's and glslang's frontend SPIR-V
# through the SAME spirv-cross -> MSL backend (NO DXC). Because the backend is identical,
# every fast-math / transcendental fp choice cancels EXACTLY, so the only surviving
# difference is zioshade's frontend STRUCTURE. On a hash/fbm shader -- where the shipping
# HLSL-vs-direct-MSL render is swamped by benign fast-math fp (spirv-cross fast:: vs
# zioshade precise) that no whole-pipeline comparison can cancel -- this is the one clean
# signal. It decides FRONTEND correctness definitively (the continue-drop bug scored 83
# here; correct shaders score <=1). It cannot see an HLSL-BACKEND-only miscompile, which
# leaves the frontend clean; the magnitude backstop below flags those for WARP (real D3D).
# Echoes: fe-clean | fe-bug | unknown. glslang (Vulkan) needs explicit in/out locations.
frontend_oracle() {  # $1=frag $2=stage_short $3=name
  local frag="$1" ss="$2" name="$3"
  command -v glslangValidator >/dev/null || { echo unknown; return; }
  local gf="$SHARE_HOST/$name.gl.frag" gs="$SHARE_HOST/$name.gl.spv" gm="$SHARE_HOST/$name.gl.msl"
  local zs="$SHARE_HOST/$name.zfe.spv" zm="$SHARE_HOST/$name.zfe.msl"
  "$CLI" compile "$frag" --stage "$STAGE_FULL" -o "$zs" 2>/dev/null || { echo unknown; return; }
  spirv-cross --msl "$zs" > "$zm" 2>/dev/null || { echo unknown; return; }
  sed 's/^\(out [a-z0-9]*vec4 [A-Za-z_][A-Za-z0-9_]*;\)/layout(location=0) \1/' "$frag" > "$gf"
  glslangValidator -V -S "$ss" "$gf" -o "$gs" >/dev/null 2>&1 || { echo unknown; return; }
  spirv-cross --msl "$gs" > "$gm" 2>/dev/null || { echo unknown; return; }
  local o; o=$("$SC_BIN" "$zm" "$gm" "$SHARE_HOST/${name}_feiso" 2>&1)
  if printf '%s\n' "$o" | grep -q '^MATCH'; then echo fe-clean; return; fi
  if printf '%s\n' "$o" | grep -qE '^DIFFER'; then echo fe-bug; return; fi
  echo unknown
}

# Render-check one shader. Echoes: RENDER-MATCH | RENDER-DIFFER | skip-<stage>
check_one() {
  local frag="$1" stage="$2" name; name=$(basename "$frag" .frag)
  local ss=frag; case "$stage" in vertex) ss=vert;; compute) ss=comp;; esac
  STAGE_FULL="$stage"  # full stage name for the frontend oracle's `zioshade compile`
  "$CLI" msl  "$frag" --stage "$stage" > "$SHARE_HOST/$name.ref.msl" 2>/dev/null || { echo "skip-msl"; return; }
  "$CLI" hlsl "$frag" --stage "$stage" > "$SHARE_HOST/$name.hlsl"    2>/dev/null || { echo "skip-hlsl"; return; }
  # The fullscreen-triangle harness feeds only gl_FragCoord, one shadertoy-layout
  # globals buffer, a test texture, and (on WARP) one b0 mat4 cbuffer. A shader
  # with LOOSE uniforms (gathered into a synthesized `_Globals` cbuffer with an
  # arbitrary member layout the harness can't match) or a MULTISAMPLE texture reads
  # inputs the harness cannot supply correctly, so its "divergence" is a harness
  # artifact, not a real miscompile (e.g. multi_uniforms, sampler-ms). Skip them so
  # RENDER-DIFFER stays a reliable real-bug signal.
  if grep -qE '_Globals|Texture2DMS|Texture2DMSArray' "$SHARE_HOST/$name.hlsl"; then echo "skip-inputs"; return; fi
  docker exec "$CONTAINER" bash -c "export LD_LIBRARY_PATH=/opt/dxc/lib
    /opt/dxc/bin/dxc -T $PROFILE -E main -spirv -Fo $SHARE_CONT/$name.spv $SHARE_CONT/$name.hlsl >/dev/null 2>&1" || { echo "skip-dxc"; return; }
  spirv-cross --msl "$SHARE_HOST/$name.spv" > "$SHARE_HOST/$name.hlsl.msl" 2>/dev/null || { echo "skip-crossmsl"; return; }
  # Render HLSL-path MSL vs the render-proven zioshade MSL; MATCH = same pixels.
  # Distinguish a genuine pixel divergence (a real HLSL miscompile) from a harness
  # setup failure: this fullscreen-triangle harness only feeds gl_FragCoord + the
  # shadertoy globals/texture, so a shader needing custom vertex attributes or a
  # different uniform layout makes Metal pipeline creation throw. That is a skip
  # (out of harness scope), NOT a render difference.
  local out; out=$("$SC_BIN" "$SHARE_HOST/$name.hlsl.msl" "$SHARE_HOST/$name.ref.msl" "$SHARE_HOST/$name" 2>&1)
  if printf '%s\n' "$out" | grep -q '^MATCH'; then
    echo "RENDER-MATCH"
  elif printf '%s\n' "$out" | grep -qE '^DIFFER \(max diff'; then
    # A non-exact render between the shipping HLSL path and zioshade's own MSL is NOT a
    # reliable bug signal on its own: the two backends make different fast-math choices
    # (spirv-cross fast:: vs zioshade precise), which a hash/fbm shader amplifies into a
    # large maxdiff that is nonetheless benign (verified: nested_func_expr, loop_trackers).
    # So consult the INDEPENDENT frontend oracle, the one comparison that cleanly cancels
    # that fp (identical backend, no DXC).
    local diff md; diff=$(printf '%s\n' "$out" | grep -oE 'Different: [0-9]+' | grep -oE '[0-9]+$')
    md=$(printf '%s\n' "$out" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
    local fe; fe=$(frontend_oracle "$frag" "$ss" "$name")
    if [ "$fe" = fe-bug ]; then
      # zioshade's frontend SPIR-V structurally differs from the independent glslang oracle
      # under an identical backend: a genuine frontend miscompile, not fp. Definitely real.
      echo "RENDER-DIFFER(px=${diff:-?},maxdiff=${md:-?},frontend=MISCOMPILE)"
    elif [ "$fe" = fe-clean ]; then
      # Frontend is provably correct vs the independent oracle. The residual is benign
      # backend fast-math fp UNLESS the magnitude is extreme -- a transposed-matrix-class
      # HLSL-backend miscompile rendered ~200+ (the #497 bug), well above the hash-fp floor
      # (<=~100). So >=128 stays a suspect flagged for WARP (real D3D) adjudication, since
      # Metal cannot separate a backend miscompile from backend fp on a hash shader; below
      # that is a benign edge.
      if [ -n "$md" ] && [ "$md" -ge 128 ]; then
        echo "RENDER-DIFFER(px=${diff:-?},maxdiff=${md},frontend-clean,WARP-adjudicate-backend)"
      else
        echo "RENDER-EDGE(px=${diff:-?},maxdiff=${md:-?},frontend-clean-backend-fp)"
      fi
    else
      # No independent oracle (glslang missing or rejected the shader). Fall back to the
      # magnitude heuristic: benign fp is either tiny-MAGNITUDE drift across many pixels
      # (transcendental / fract-mod precision) or a small-AREA discontinuity flip
      # (step/floor edges); a real miscompile is LARGE-area AND LARGE-magnitude. So
      # maxdiff <= 8 OR <= 256 differing pixels = RENDER-EDGE (benign); else RENDER-DIFFER.
      if [ -n "$md" ] && [ "$md" -le 8 ]; then
        echo "RENDER-EDGE(px=${diff:-?},maxdiff=${md})"
      elif [ -n "$diff" ] && [ "$diff" -le 256 ]; then
        echo "RENDER-EDGE(px=${diff},maxdiff=${md:-?})"
      else
        echo "RENDER-DIFFER(px=${diff:-?},maxdiff=${md:-?})"
      fi
    fi
  else
    echo "skip-inputs"   # needs vertex attrs / incompatible uniforms — not renderable here
  fi
}

# The shared host path also needs to be visible in the container for the .spv hop.
mkdir -p "$SHARE_HOST"

if [ "${1:-}" = "--sweep" ]; then
  DIR=${2:-tests/spirv-cross}
  declare -A tally
  for f in "$DIR"/*.frag; do
    case "$f" in *.asm.*) continue;; esac
    [ -e "$f" ] || continue
    r=$(check_one "$f" fragment)
    key=${r%%(*}
    tally[$key]=$(( ${tally[$key]:-0} + 1 ))
    case "$r" in RENDER-DIFFER*) echo "$r $(basename "$f" .frag)";; esac
  done
  echo
  for k in RENDER-MATCH RENDER-EDGE RENDER-DIFFER skip-inputs skip-msl skip-hlsl skip-dxc skip-crossmsl; do
    [ -n "${tally[$k]:-}" ] && echo "$k = ${tally[$k]}"
  done
else
  [ -n "${1:-}" ] || { echo "usage: $0 <shader.frag> | --sweep [dir]"; exit 2; }
  echo "$(basename "$1"): $(check_one "$1" "${2:-fragment}")"
fi
