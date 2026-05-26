#!/usr/bin/env python3
"""Categorize tests/conformance/stress/ files by topic for TEST_COVERAGE.md.

Usage:  python scripts/categorize_stress.py
"""
import os, sys
from collections import defaultdict

CATEGORIES = {
    "Control flow (if/else, switch, ternary)": ["if", "else", "switch", "tern", "cond", "branch", "default", "select"],
    "Loops (for, while, do-while)": ["for", "while", "dowhile", "loop", "continue", "break"],
    "Early return / discard": ["early_ret", "multi_ret", "discard", "ret"],
    "Structs and arrays": ["struct", "array", "arr"],
    "Vectors and matrices": ["vec", "mat", "swizzle", "bvec", "ivec", "uvec"],
    "Integer / bitwise math": ["int", "uint", "bool", "bit", "shift", "logic"],
    "Floating-point math / built-ins": ["math", "trig", "exp", "log", "smoothstep", "mix",
        "saturate", "step", "fract", "floor", "ceil", "atan", "sin", "cos", "deriv", "fma"],
    "Function calls / chains": ["func", "call", "chain", "inout", "param", "fn"],
    "Memory / load-store / aliasing": ["load", "store", "copy", "alias", "ptr", "addr"],
    "Textures / sampling": ["tex", "sample", "uv", "albedo", "bind"],
    "Compute / atomic / SSBO": ["compute", "comp", "atomic", "ssbo", "barrier", "workgroup", "shared"],
    "Geometry / vertex specifics": ["vertex", "geom", "tess", "instance", "frag_depth", "depth_write"],
    "Specific shader patterns": ["mandelbrot", "voronoi", "noise", "ray", "sdf", "raymarch",
        "fbm", "perlin", "checkerboard", "tonemap", "fog", "phong", "pbr", "brdf", "particle"],
}

def main():
    root = os.path.join("tests", "conformance", "stress")
    if not os.path.isdir(root):
        print(f"error: {root} not found (run from repo root)", file=sys.stderr)
        sys.exit(1)
    files = sorted(f for f in os.listdir(root) if not f.startswith("."))

    by_cat = defaultdict(list)
    unassigned = []
    for f in files:
        base = f.lower()
        for cat, kws in CATEGORIES.items():
            if any(kw in base for kw in kws):
                by_cat[cat].append(f)
                break
        else:
            unassigned.append(f)

    print(f"Total: {len(files)}\n")
    rows = []
    for cat in CATEGORIES:
        items = by_cat[cat]
        if items:
            sample = ", ".join(f"`{x}`" for x in items[:4])
            rows.append((len(items), cat, sample))
    if unassigned:
        sample = ", ".join(f"`{x}`" for x in unassigned[:4])
        rows.append((len(unassigned), "Misc / new feature regressions", sample))
    rows.sort(reverse=True)
    print("| # | Category | Examples |")
    print("|---:|---|---|")
    for n, cat, sample in rows:
        print(f"| {n} | {cat} | {sample} |")

if __name__ == "__main__":
    main()
