#!/usr/bin/env bash
# MSL compile oracle: resolve whichever Metal compiler this machine actually has and
# compile-check one .metal file with it. Shared by the SPIR-V-input sweeps
# (tools/spv_input_validity_sweep.sh, tools/cts_ingestion_sweep.sh) so both agree on
# what "Metal accepts this" means, on a developer Mac and on a CI runner alike.
#
# Two oracles, in preference order:
#   xcrun  offline metal frontend (`xcrun metal -c`). Preferred: it needs no GPU and no
#          Metal device, so it works on a headless/virtualized CI runner.
#   swift  tools/MslCompileCheck.swift (MTLDevice.makeLibrary), built on demand into
#          .zig-cache/mslcheck. Needs swiftc AND a usable Metal device at runtime.
# Neither present -> exit 2 (no oracle), which callers treat as SKIP, never as a pass.
#
# Availability is probed by COMPILING a known-good trivial shader, not by asking whether
# a binary exists: swiftc ships on Linux without the Metal framework, and an `xcrun -f
# metal` hit does not prove the Metal toolchain component is installed. Probing the real
# capability is the same rule the sibling sweeps already apply to dxc.
#
# Usage:
#   tools/msl_compile_check.sh --probe      print the resolved oracle name, exit 0; exit 2 if none
#   tools/msl_compile_check.sh <file.metal> exit 0 accepted, 1 rejected, 2 no oracle
#
# Env: ZIOSHADE_MSL_ORACLE=xcrun|swift  pin the oracle (skips resolution). A sweep probes
#      once and exports this so every per-file call uses the oracle the probe validated.
set -uo pipefail
cd "$(dirname "$0")/.."

CHECK=.zig-cache/mslcheck

build_swift_check() {
  command -v swiftc >/dev/null 2>&1 || return 1
  if [ ! -x "$CHECK" ] || [ tools/MslCompileCheck.swift -nt "$CHECK" ]; then
    mkdir -p .zig-cache
    swiftc -O tools/MslCompileCheck.swift -o "$CHECK" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# compile <oracle> <file.metal>; stderr (the compiler diagnostic) is passed through.
# Returns 0 accepted, 1 rejected, 2 the oracle itself could not be run. The compiler's
# own exit code is normalized to 1 so a rejection can never be confused with "no oracle"
# (MslCompileCheck already exits 2 for "cannot read file" / "no Metal device").
compile() {
  local oracle=$1 src=$2 d rc
  case "$oracle" in
    xcrun)
      d=$(mktemp -d) || return 2
      xcrun metal -c "$src" -o "$d/out.air"
      rc=$?
      rm -rf "$d"
      [ "$rc" -eq 0 ] || rc=1
      return $rc
      ;;
    swift)
      [ -x "$CHECK" ] || build_swift_check || return 2
      "$CHECK" "$src"
      rc=$?
      # MslCompileCheck exit 2 = it could not run at all (unreadable file, no Metal
      # device), which is an oracle failure, not a rejection of the shader.
      [ "$rc" -eq 2 ] && return 2
      [ "$rc" -eq 0 ] || rc=1
      return $rc
      ;;
    *) return 2;;
  esac
}

available() {
  case "$1" in
    xcrun) xcrun -f metal >/dev/null 2>&1;;
    swift) build_swift_check;;
    *) return 1;;
  esac
}

if [ "${1:-}" = "--probe" ]; then
  d=$(mktemp -d) || exit 2
  trap 'rm -rf "$d"' EXIT
  cat > "$d/probe.metal" <<'MSL'
#include <metal_stdlib>
using namespace metal;
fragment float4 main0() { return float4(0.0); }
MSL
  for o in ${ZIOSHADE_MSL_ORACLE:-xcrun swift}; do
    available "$o" || continue
    if compile "$o" "$d/probe.metal" >/dev/null 2>&1; then echo "$o"; exit 0; fi
  done
  exit 2
fi

[ $# -ge 1 ] || { echo "usage: tools/msl_compile_check.sh <file.metal> | --probe" >&2; exit 2; }

for o in ${ZIOSHADE_MSL_ORACLE:-xcrun swift}; do
  available "$o" || continue
  compile "$o" "$1"
  exit $?
done
exit 2
