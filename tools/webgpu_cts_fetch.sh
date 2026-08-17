#!/usr/bin/env bash
# Regenerate the vendored WebGPU CTS WGSL corpus slice (tests/webgpu_cts/).
# NOT part of the sweep: tools/webgpu_cts_sweep.sh only consumes the committed
# cases + manifest, so `just webgpu-cts` runs anywhere naga + the CLI exist.
# Run this only when deliberately refreshing the corpus; it needs network,
# node+npm+tsc and ~2 min, and it REWRITES tests/webgpu_cts/cases + manifest
# (then re-run tools/webgpu_cts_sweep.sh and update tests/webgpu_cts/baseline.txt).
#
# Pipeline (direction rationale in tools/webgpu_cts_dump.mjs and the sweep
# header): sparse-clone gpuweb/cts at a PINNED commit -> tsc-emit the TS tree
# to plain JS -> drive the CTS's own case enumeration headlessly, capturing
# every per-case WGSL the framework would have compiled (no GPU) -> carve a
# deterministic bounded slice (sha1 order, 100 unique shaders per spec file:
# 1614 cases / ~319 KB of WGSL from the 91 validation spec files at 2959e1c).
#
# Usage: tools/webgpu_cts_fetch.sh [cts-commit]   (default: the pinned one)
set -euo pipefail
cd "$(dirname "$0")/.."

CTS_COMMIT=${1:-2959e1c}   # pinned: "Subgroup_size_control enables subgroups (#4693)"
WORK=${WORK:-$(mktemp -d)}
SLICE=${SLICE:-tests/webgpu_cts}

echo "== sparse clone gpuweb/cts @ $CTS_COMMIT =="
git clone --filter=blob:none --no-checkout https://github.com/gpuweb/cts.git "$WORK/cts"
git -C "$WORK/cts" checkout "$CTS_COMMIT"
git -C "$WORK/cts" sparse-checkout set src

echo "== npm install + tsc emit =="
( cd "$WORK/cts" && npm install --no-audit --no-fund )
( cd "$WORK/cts" && npx tsc -p tsconfig.json --noEmit false \
  --declaration false --outDir "$WORK/js" )
echo '{"type":"module"}' > "$WORK/js/package.json"

echo "== dump per-case WGSL (headless) =="
node tools/webgpu_cts_dump.mjs "$WORK/js" "$WORK/dump.json"

echo "== carve the bounded slice into $SLICE =="
python3 tools/webgpu_cts_extract.py "$WORK/dump.json" "$SLICE" --per-file "${PER_FILE:-100}"

echo
echo "Done. If the corpus changed: re-run tools/webgpu_cts_sweep.sh and refresh"
echo "$SLICE/baseline.txt + the pinned commit in this script and the README."
