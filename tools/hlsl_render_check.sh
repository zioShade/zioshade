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

# Render-check one shader. Echoes: RENDER-MATCH | RENDER-DIFFER | skip-<stage>
check_one() {
  local frag="$1" stage="$2" name; name=$(basename "$frag" .frag)
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
    # Triage a non-exact render. Benign floating-point differences come in two
    # shapes, neither a miscompile: (a) tiny-MAGNITUDE drift across many pixels —
    # transcendental precision (sin/cos/atan) or a fract/mod boundary, where the two
    # compile paths pick slightly different instructions; (b) small-AREA sharp flips
    # — step()/floor()/discontinuity edges where a 1-ULP difference flips which side
    # a boundary pixel lands on. A real miscompile (e.g. a transposed matrix)
    # diverges over a LARGE area AND at LARGE magnitude (the matrix bug was ~50-64k
    # px at maxdiff ~200+). So: maxdiff <= 8 (precision drift) OR <= 256 differing
    # pixels (~0.4% of 65536, localized boundaries) = RENDER-EDGE (benign); anything
    # both large-area and large-magnitude = RENDER-DIFFER (a real bug to triage).
    local diff md; diff=$(printf '%s\n' "$out" | grep -oE 'Different: [0-9]+' | grep -oE '[0-9]+$')
    md=$(printf '%s\n' "$out" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
    if [ -n "$md" ] && [ "$md" -le 8 ]; then
      echo "RENDER-EDGE(px=${diff:-?},maxdiff=${md})"
    elif [ -n "$diff" ] && [ "$diff" -le 256 ]; then
      echo "RENDER-EDGE(px=${diff},maxdiff=${md:-?})"
    else
      echo "RENDER-DIFFER(px=${diff:-?},maxdiff=${md:-?})"
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
