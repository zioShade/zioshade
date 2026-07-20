#!/usr/bin/env bash
# HLSL backend-validity sweep: cross-compile every shader in a corpus to HLSL and
# compile-check the output with DXC (the DirectX Shader Compiler). This is the HLSL
# analog of tools/msl_validity_sweep.sh (MSL->Metal) and backend_validity_sweep.sh
# (GLSL->glslangValidator, WGSL->naga): a real backend-validity oracle that catches
# the silent-wrong class (emit valid-looking HLSL at exit 0 that DXC rejects).
#
# DXC runs inside a docker container (Microsoft ships only Linux/Windows DXC
# binaries; there is no macOS build). The container `dxc-oracle` must be running
# with this scratchpad mounted at /work and DXC unpacked under /opt/dxc:
#   docker run -d --name dxc-oracle --platform linux/amd64 \
#     -v <scratchpad>:/work catthehacker/ubuntu:act-latest sleep infinity
#   docker exec dxc-oracle bash -c 'cd /opt && curl -sL <linux_dxc>.tar.gz -o d.tgz \
#     && mkdir -p dxc && tar xzf d.tgz -C dxc'
#
# Emission runs on the host (fast); validation is ONE `docker exec` that loops
# inside the container (per-shader docker exec is far too slow under emulation).
#
# Usage: tools/hlsl_validity_sweep.sh [dir] [stage] [ext] [profile]
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tests/spirv-cross}
STAGE=${2:-fragment}
EXT=${3:-frag}
PROFILE=${4:-ps_6_0}
CLI=${CLI:-zig-out/bin/zioshade}
CONTAINER=${CONTAINER:-dxc-oracle}

# Host path of the scratchpad mount and the matching in-container path.
SHARE_HOST=/private/tmp/claude-501/-Users-alex-claude/2e7ff35b-0e04-4cb1-9600-f56f35b3f7b7/scratchpad/hlslsweep
SHARE_CONT=/work/hlslsweep

[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
docker exec "$CONTAINER" true 2>/dev/null || { echo "error: container $CONTAINER not running"; exit 2; }

rm -rf "$SHARE_HOST"; mkdir -p "$SHARE_HOST"

# Emit phase (host): valid emission -> a .hlsl file DXC will check; a frontend
# refusal (honest-error) writes no file and is counted separately.
herr=0 total=0
for f in "$DIR"/*."$EXT"; do
  [ -e "$f" ] || continue
  case "$f" in *.asm.*) continue;; esac   # SPIR-V assembly, not GLSL source
  total=$((total+1))
  name=$(basename "$f" ".$EXT")
  if "$CLI" hlsl "$f" --stage "$STAGE" > "$SHARE_HOST/$name.hlsl" 2>/dev/null; then
    :
  else
    rm -f "$SHARE_HOST/$name.hlsl"
    herr=$((herr+1))
  fi
done

# Validate phase (container, single exec): DXC-compile each emitted file.
# valid = DXC accepts; INVALID = DXC rejects (backend bug, the gate).
docker exec "$CONTAINER" bash -c '
  export LD_LIBRARY_PATH=/opt/dxc/lib
  ok=0; bad=0
  for h in '"$SHARE_CONT"'/*.hlsl; do
    [ -e "$h" ] || continue
    if /opt/dxc/bin/dxc -T '"$PROFILE"' -E main -Wno-ignored-attributes "$h" >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      bad=$((bad+1)); echo "INVALID $(basename "$h" .hlsl)"
    fi
  done
  echo "__COUNTS__ ok=$ok bad=$bad"
'

echo
echo "HLSL honest-error (frontend refused) = $herr / $total total"
