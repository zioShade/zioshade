#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"

RUNNER=.zig-cache/bin/conformance-runner.exe
if [ ! -f "$RUNNER" ]; then
    echo "Building..." >&2
    mkdir -p .zig-cache/bin
    timeout 120 zig build-exe -OReleaseSafe --dep glslpp -Mroot=tests/runner.zig -Mglslpp=src/root.zig --cache-dir .zig-cache -femit-bin=.zig-cache/bin/conformance-runner.exe 2>/dev/null || true
fi
if [ ! -f "$RUNNER" ]; then echo "ERROR: no runner"; echo "METRIC our_bound=0"; exit 0; fi

CACHE=".zig-cache/ref_classification.txt"
if [ ! -f "$CACHE" ]; then
    echo "ERROR: no classification cache. Run autoresearch.sh first." >&2
    echo "METRIC our_bound=0"
    exit 0
fi

python3 -c "
import struct, subprocess, os
cache = '$CACHE'
runner = '$RUNNER'
our_total = 0
count = 0
with open(cache) as f:
    for line in f:
        parts = line.strip().split(' ', 1)
        if len(parts) < 2 or parts[0] != 'VALID': continue
        spv = '.zig-cache/_bound_cmp.spv'
        subprocess.run([runner, parts[1], '--save-spv', spv], capture_output=True, timeout=5)
        try:
            with open(spv, 'rb') as fh:
                d = fh.read()
                if len(d) >= 16:
                    ob = struct.unpack('<I', d[12:16])[0]
                    our_total += ob
                    count += 1
        except: pass
        try: os.remove(spv)
        except: pass
print(f'METRIC our_bound={our_total}')
print(f'count={count}', file=__import__('sys').stderr)
"
