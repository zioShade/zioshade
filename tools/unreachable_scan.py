#!/usr/bin/env python3
"""Find unreachable statements in emitted shader source, all four backends.

A statement that follows a statement-level `break;`, `continue;`, `return ...;`
or `discard;` in the SAME block can never execute. In generated code that is
never a style choice: it means the emitter wrote a terminator it should not
have, and everything after it in that block was silently dropped from the
program. The output still compiles, so no validity gate sees it, and the
structural-drop sweep does not either -- that one counts loops and switches,
not reachability.

This detector has found two real miscompiles:

  #599  WGSL emitted a second, unconditional `break;` after a loop's conditional
        break, orphaning the rest of the body in 36 corpus shaders. Every
        mandelbrot, ray-march and search-loop in the corpus computed nothing.
  #604  WGSL treated a selection's own merge block as a break/continue
        trampoline, which inverted the selection and left graphicsfuzz_061's
        loop exit test after an unconditional `return`. That loop had no exit.

Three exclusions, each learned by getting a count wrong first:

  `continuing {` after a break is NOT unreachable code. It is part of the
  enclosing WGSL `loop` construct rather than a statement. Counting it reported
  14 false positives out of 50 when measuring #599.

  A `case`/`default` label after a terminator is the next arm of a C-family
  switch, not a continuation of the current one.

  A `return` line without a trailing `;` opens a MULTI-LINE return expression
  (`return mat3x3<f32>(`), whose continuation lines are perfectly reachable.

MEASURED BASELINE on main @234ff67a, both corpora (1511 spirv-cross + 88 CTS).
Everything below is assessed benign; this is a diagnostic, not yet a gate.

  wgsl  0 of 1478          clean, after #599 and #604
  glsl  1 of 1494          switch_nested_func: a dead `break;` after a `return;`
  msl   54 of 1498         the early-return-chain duplication, bd zioshade-1hg
  hlsl  1463 of 1478       1471 identical duplicate `return X;` (bd, cosmetic)
                           plus the same 54 duplication shaders as MSL

The duplication class is bloat, not a miscompile: the continuation is emitted
inside each arm AFTER its return (dead) and again at the correct scope (live).
Render-diffed via prove_opt: color-ramp, early_ret3 and early_return_nested all
MATCH. It becomes a gate once zioshade-1hg lands.

Usage: unreachable_scan.py <cli> <backend> <file>...
Prints one line per affected shader and a total.
"""

import re
import subprocess
import sys

TERMINATORS = ("break;", "continue;", "discard;")

# `case 3: {`, `default: {`, `default {` -- a new switch arm, not a continuation.
ARM_RE = re.compile(r"^(case\b|default\b)")


def is_terminator(s):
    """A statement-level terminator, complete on one line.

    The trailing `;` matters: `return mat3x3<f32>(` opens a multi-line return
    expression whose continuation lines are NOT unreachable. Without this check
    mat_inverse_chain.wgsl reported a false drop, which is exactly the kind of
    noise that makes a detector get ignored."""
    if s in TERMINATORS:
        return True
    return s.startswith("return") and s.endswith(";")


def unreachable_statements(src):
    """[(line_no, terminator, orphaned_statement)] for each block-level drop."""
    lines = src.splitlines()
    hits = []
    for i, line in enumerate(lines):
        s = line.strip()
        if not is_terminator(s):
            continue
        indent = len(line) - len(line.lstrip())
        for nxt in lines[i + 1:]:
            t = nxt.strip()
            if not t:
                continue
            nind = len(nxt) - len(nxt.lstrip())
            if nind < indent:
                break                       # the enclosing block ended
            if t.startswith("}"):
                break                       # this block ended
            if t.startswith("continuing"):
                break                       # part of the WGSL `loop` construct
            if ARM_RE.match(t):
                break                       # next switch arm
            hits.append((i + 1, s, t))
            break
    return hits


def main():
    cli, backend, files = sys.argv[1], sys.argv[2], sys.argv[3:]
    affected, emitted = 0, 0
    for f in files:
        p = subprocess.run([cli, backend, f], capture_output=True, text=True, timeout=180)
        if p.returncode != 0:
            continue
        emitted += 1
        hits = unreachable_statements(p.stdout)
        if hits:
            affected += 1
            ln, term, stmt = hits[0]
            extra = f" (+{len(hits) - 1} more)" if len(hits) > 1 else ""
            print(f"  {f.split('/')[-1]}: line {ln} after `{term}` -> `{stmt[:60]}`{extra}")
    print(f"{backend}: {affected} affected of {emitted} emitted")
    return 1 if affected else 0


if __name__ == "__main__":
    sys.exit(main())
