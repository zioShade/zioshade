#!/usr/bin/env bash
# HLSL compile oracle: resolve whichever DXC this machine actually has and compile-check
# one .hlsl file with it. Shared by the SPIR-V-input sweeps
# (tools/spv_input_validity_sweep.sh, tools/cts_ingestion_sweep.sh) so both agree on what
# "DXC accepts this" means, on a developer Mac and on a Windows CI runner alike.
#
# Two oracles, in preference order:
#   native  a real `dxc` on PATH. This is what a Windows runner gets from the LunarG
#           Vulkan SDK (which ships dxc.exe), and it needs no Docker.
#   docker  /opt/dxc/bin/dxc inside the `dxc-oracle` container (how macOS/Linux devs run
#           DXC; it needs LD_LIBRARY_PATH=/opt/dxc/lib and is NOT on PATH).
# Neither present -> exit 2 (no oracle), which callers treat as SKIP, never as a pass.
#
# Availability is probed by COMPILING a known-good trivial shader, not by asking whether
# a binary exists: a running container whose dxc is not invokable, or a dxc.exe without
# its dxcompiler runtime next to it, would otherwise make every file false-classify as
# oracle-limit (silent masking). Note also that on some dev machines `dxc` is an
# interactive shell ALIAS for `docker container exec`, which does not expand in a
# non-interactive shell, so the native probe correctly fails there and we fall through.
#
# -Fo needs a real writable path (on Windows /dev/null is not a valid dxc output target),
# so we always compile to a throwaway file and delete it. Under Git Bash on Windows the
# MSYS runtime rewrites the POSIX paths we pass into Windows paths for the native dxc.exe.
#
# Usage:
#   tools/hlsl_compile_check.sh --probe              print the resolved oracle name, exit 0; 2 if none
#   tools/hlsl_compile_check.sh <profile> <file>     exit 0 accepted, 1 rejected, 2 no oracle
#     profile  a DXC target profile, e.g. ps_6_0 / vs_6_0 / cs_6_0
#
# Env: ZIOSHADE_HLSL_ORACLE=native|docker  pin the oracle (skips resolution). A sweep
#      probes once and exports this so every per-file call uses the probed oracle.
#      CONTAINER=<name>  container for the docker oracle (default dxc-oracle).
set -uo pipefail
cd "$(dirname "$0")/.."

CONTAINER=${CONTAINER:-dxc-oracle}
DXCFLAGS=${DXCFLAGS:--Wno-ignored-attributes}

# compile <oracle> <profile> <file.hlsl>; stderr (the compiler diagnostic) passes through.
# Returns 0 accepted, 1 rejected, 2 the oracle itself could not be run. DXC's own exit
# code is normalized to 1 so that a rejection can never be confused with "no oracle"
# (DXC returns 5, not 1, for a syntax error).
compile() {
  local oracle=$1 prof=$2 src=$3 d rc guest
  case "$oracle" in
    native)
      d=$(mktemp -d) || return 2
      dxc $DXCFLAGS -T "$prof" -E main "$src" -Fo "$d/out.dxil"
      rc=$?
      rm -rf "$d"
      [ "$rc" -eq 0 ] || rc=1
      return $rc
      ;;
    docker)
      guest=/tmp/zs_check_$$.hlsl
      docker cp "$src" "$CONTAINER:$guest" >/dev/null 2>&1 || return 2
      docker exec -e LD_LIBRARY_PATH=/opt/dxc/lib "$CONTAINER" \
        /opt/dxc/bin/dxc $DXCFLAGS -T "$prof" -E main "$guest" -Fo /tmp/zs_check_$$.dxil
      rc=$?
      docker exec "$CONTAINER" rm -f "$guest" /tmp/zs_check_$$.dxil >/dev/null 2>&1
      [ "$rc" -eq 0 ] || rc=1
      return $rc
      ;;
    *) return 2;;
  esac
}

available() {
  case "$1" in
    native) command -v dxc >/dev/null 2>&1;;
    docker) command -v docker >/dev/null 2>&1 && docker exec "$CONTAINER" true >/dev/null 2>&1;;
    *) return 1;;
  esac
}

if [ "${1:-}" = "--probe" ]; then
  d=$(mktemp -d) || exit 2
  trap 'rm -rf "$d"' EXIT
  cat > "$d/probe.hlsl" <<'HLSL'
float4 main() : SV_TARGET { return float4(0.0, 0.0, 0.0, 0.0); }
HLSL
  for o in ${ZIOSHADE_HLSL_ORACLE:-native docker}; do
    available "$o" || continue
    if compile "$o" ps_6_0 "$d/probe.hlsl" >/dev/null 2>&1; then echo "$o"; exit 0; fi
  done
  exit 2
fi

[ $# -ge 2 ] || { echo "usage: tools/hlsl_compile_check.sh <profile> <file.hlsl> | --probe" >&2; exit 2; }

for o in ${ZIOSHADE_HLSL_ORACLE:-native docker}; do
  available "$o" || continue
  compile "$o" "$1" "$2"
  exit $?
done
exit 2
