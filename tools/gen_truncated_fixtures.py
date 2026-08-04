#!/usr/bin/env python3
"""Generate truncated-instruction SPIR-V negative fixtures.

Each fixture is a real GraphicsFuzz module with exactly one instruction
rewritten to be one word SHORTER than the SPIR-V spec minimum for its opcode.
The dropped operand words are deleted so the instruction stream stays aligned
and the rest of the module parses normally.

These fixtures exist to prove the parser rejects a short instruction with a
loud error instead of letting a backend emit arm index past the end of
`inst.words`. Run from the repo root:

    python3 tools/gen_truncated_fixtures.py
"""

import glob
import os
import struct

OUT = "src/testdata"

# Opcodes whose emit arms index words[>=3], with their spec minimum word count.
TARGETS = {
    65: ("AccessChain", 4),
    79: ("VectorShuffle", 5),
    57: ("FunctionCall", 4),
}


def main():
    produced = {}
    for path in sorted(glob.glob("tests/cts/graphicsfuzz/*.spv")):
        raw = open(path, "rb").read()
        w = list(struct.unpack("<%dI" % (len(raw) // 4), raw))
        if not w or w[0] != 0x07230203:
            continue
        i = 5
        while i < len(w):
            wc = w[i] >> 16
            op = w[i] & 0xFFFF
            if wc == 0:
                break
            if op in TARGETS:
                name, minwc = TARGETS[op]
                if name not in produced and wc > minwc:
                    # One word shorter than the spec minimum.
                    newwc = minwc - 1
                    out = w[:i] + [(newwc << 16) | op] + w[i + 1 : i + newwc] + w[i + wc :]
                    fn = "%s/truncated_%s.spv" % (OUT, name.lower())
                    with open(fn, "wb") as f:
                        f.write(b"".join(struct.pack("<I", x) for x in out))
                    produced[name] = (fn, path)
                    break
            i += wc
        if len(produced) == len(TARGETS):
            break

    for name, (fn, src) in sorted(produced.items()):
        print("wrote %s (from %s)" % (fn, src))
    missing = sorted(set(n for n, _ in TARGETS.values()) - set(produced))
    if missing:
        print("no source instruction found for: %s" % ", ".join(missing))


if __name__ == "__main__":
    main()
