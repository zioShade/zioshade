#!/usr/bin/env python3
"""zioshade - version sync gate.

build.zig.zon's `.version` (what the package manager and release tags care
about) and src/version.zig's `version_string` (what `zioshade --version`
prints) cannot share one source of truth: the zon is not importable. This gate
fails when they drift, so a released binary can always be tied back to the
tag it was cut from. Same shape as gen_min_word_count.py --check: a hand edit
on either side that desynchronizes the pair is a silent-misreport hazard, so
it is a gate, not a convention.

Usage:
    python3 tools/check_version_sync.py            # check, nonzero exit on drift
    python3 tools/check_version_sync.py --fix      # rewrite version.zig from the zon
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ZON = REPO / "build.zig.zon"
VER = REPO / "src" / "version.zig"


def zon_version() -> str:
    text = ZON.read_text(encoding="utf-8")
    m = re.search(r'^\s*\.version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    if not m:
        sys.exit("error: no .version found in build.zig.zon")
    return m.group(1)


def source_version() -> str | None:
    text = VER.read_text(encoding="utf-8")
    m = re.search(r'pub const version_string\s*=\s*"([^"]+)"', text)
    return m.group(1) if m else None


def main() -> int:
    fix = "--fix" in sys.argv[1:]
    zv = zon_version()
    sv = source_version()
    if sv == zv:
        print(f"version sync: OK ({zv})")
        return 0
    if sv is None:
        sys.exit("error: no version_string found in src/version.zig")
    if fix:
        text = VER.read_text(encoding="utf-8")
        VER.write_text(
            re.sub(
                r'pub const version_string\s*=\s*"[^"]+"',
                f'pub const version_string = "{zv}"',
                text,
            ),
            encoding="utf-8",
        )
        print(f"version sync: FIXED src/version.zig -> {zv}")
        return 0
    print(
        f"error: version drift: build.zig.zon says {zv} but src/version.zig says {sv}. "
        "Bump both together (or run with --fix to take the zon's value).",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
