#!/usr/bin/env python3
"""Structural-drop detector for the WGSL backend.

The 2026-07-28 control-flow-count sweep proved zero silent structural drops across
MSL, GLSL and HLSL by comparing counts in the emitted source against the INPUT
SPIR-V. It never ran against WGSL, and PR #581 found a live drop there: four
switch-breaks taken from inside a selection were emitted as empty `if` bodies.
The output still compiled, so no validity gate could see it.

This is the WGSL equivalent. It reports DROPS (output has fewer than the input
requires). Extra constructs in the output are not flagged: lowering legitimately
introduces `loop`/`break` that the SPIR-V does not name one-for-one.

Three counters:

  loops    OpLoopMerge            -> `loop {`
  switches OpSwitch               -> `switch <sel> {`
  breaks   OpBranch to a switch's merge label from a block that is NOT one of
           that switch's case labels -- i.e. a break taken from inside a nested
           selection. A case body's own terminating branch to the merge needs no
           `break;`, because WGSL switch cases do not fall through, so counting
           every branch-to-merge would produce noise. This counter is the one
           that catches #581.

Honest errors are excluded: a shader zioshade refuses emits nothing, which is a
refusal rather than a drop.

Usage: python3 tools/wgsl_structural_drop_sweep.py [--verbose]
Exit 1 if any drop is found.
"""

import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.environ.get("ZIOSHADE_CLI") or os.path.join(ROOT, "zig-out/bin/zioshade")

LABEL_RE = re.compile(r"^\s*%(\w+) = OpLabel")
SWITCH_RE = re.compile(r"^\s*OpSwitch %\w+ %(\w+)((?:\s+\d+\s+%\w+)*)")
SEL_MERGE_RE = re.compile(r"^\s*OpSelectionMerge %(\w+)")
BRANCH_RE = re.compile(r"^\s*OpBranch %(\w+)\s*$")


def spirv_expectations(spv_path):
    """(loops, switches, nested_switch_breaks) required by the input module."""
    try:
        dis = subprocess.run(
            ["spirv-dis", spv_path], capture_output=True, text=True, timeout=60
        )
    except Exception:
        return None
    if dis.returncode != 0:
        return None
    lines = dis.stdout.splitlines()

    loops = sum(1 for ln in lines if "OpLoopMerge" in ln)
    switches = sum(1 for ln in lines if re.search(r"^\s*OpSwitch ", ln))

    # Map every OpSwitch to its merge label (from the OpSelectionMerge above it)
    # and its case labels, then count branches to that merge from other blocks.
    breaks = 0
    for i, ln in enumerate(lines):
        m = SWITCH_RE.match(ln)
        if not m:
            continue
        merge = None
        for j in range(i - 1, max(-1, i - 4), -1):
            sm = SEL_MERGE_RE.match(lines[j])
            if sm:
                merge = sm.group(1)
                break
        if merge is None:
            continue
        case_labels = set(re.findall(r"%(\w+)", m.group(2) or ""))
        case_labels.add(m.group(1))  # the default label

        # A branch to the switch's merge needs an explicit `break;` only when it is
        # an EARLY exit from inside a nested selection arm. Two other blocks also
        # branch there and need nothing:
        #   - a case label itself (the case body simply ends; WGSL cases do not
        #     fall through, so the break is implicit)
        #   - a nested selection's MERGE block, which is the natural end of the case
        #     body reached by falling out of the `if`
        # So require the block to be a BranchConditional target that is not itself a
        # merge label. Without the second exclusion graphicsfuzz_037 reported two
        # phantom drops whose SPIR-V branches come from selection merges.
        arm_labels, merge_labels = set(), set()
        for ln2 in lines:
            bc = re.match(r"^\s*OpBranchConditional %\w+ %(\w+) %(\w+)", ln2)
            if bc:
                arm_labels.add(bc.group(1))
                arm_labels.add(bc.group(2))
            sm2 = SEL_MERGE_RE.match(ln2)
            if sm2:
                merge_labels.add(sm2.group(1))

        cur = None
        for k in range(i + 1, len(lines)):
            lm = LABEL_RE.match(lines[k])
            if lm:
                cur = lm.group(1)
                if cur == merge:
                    break
                continue
            bm = BRANCH_RE.match(lines[k])
            if (
                bm
                and bm.group(1) == merge
                and cur is not None
                and cur not in case_labels
                and cur in arm_labels
                and cur not in merge_labels
            ):
                breaks += 1
    return loops, switches, breaks


def wgsl_counts(src):
    """(loops, switches, breaks-inside-a-switch-but-not-a-nested-loop)."""
    loops = len(re.findall(r"\bloop\s*\{", src))
    switches = len(re.findall(r"\bswitch\s+[^\{]*\{", src))

    # Brace-track so a `break` belonging to a nested loop is not credited to the
    # switch. In WGSL `break` binds to the nearest enclosing loop OR switch, and
    # plain blocks in between (`default: {`, `if c {`) are transparent to it -- so
    # scan DOWN the stack for the first loop/switch frame rather than looking only
    # at the top. Looking only at the top counted zero breaks for the very shader
    # this sweep exists to catch, which is why the calibration run matters.
    breaks = 0
    stack = []  # innermost-last: "switch" | "loop" | "other"
    for raw in src.splitlines():
        line = raw.strip()
        if line.startswith("break;"):
            for frame in reversed(stack):
                if frame in ("switch", "loop"):
                    if frame == "switch":
                        breaks += 1
                    break
        kind = "other"
        if re.match(r"^\s*switch\s+", raw):
            kind = "switch"
        elif re.match(r"^\s*loop\s*\{", raw):
            kind = "loop"
        for n in range(raw.count("{")):
            stack.append(kind if n == 0 else "other")
        for _ in range(raw.count("}")):
            if stack:
                stack.pop()
    return loops, switches, breaks


def main():
    verbose = "--verbose" in sys.argv
    files = sorted(glob.glob(os.path.join(ROOT, "tests/cts/graphicsfuzz/*.spv")))
    files += sorted(glob.glob(os.path.join(ROOT, "tests/spirv-cross/*.frag")))
    drops, refused, checked = [], 0, 0

    import tempfile

    tmpdir = tempfile.mkdtemp()
    for f in files:
        proc = subprocess.run(
            [CLI, "wgsl", f], capture_output=True, text=True, timeout=120
        )
        if proc.returncode != 0:
            refused += 1
            continue
        # A .frag has to be lowered first: the module the WGSL backend actually
        # consumes is the one zioshade's own frontend produces, so that is what the
        # expectations must be read from -- not the GLSL text.
        spv = f
        if f.endswith(".frag"):
            spv = os.path.join(tmpdir, "in.spv")
            c = subprocess.run(
                [CLI, "compile", f, "-o", spv], capture_output=True, timeout=120
            )
            if c.returncode != 0:
                refused += 1
                continue
        exp = spirv_expectations(spv)
        if exp is None:
            continue
        checked += 1
        got = wgsl_counts(proc.stdout)
        names = ("loop", "switch", "switch-break")
        for name, e, g in zip(names, exp, got):
            if g < e:
                drops.append((os.path.basename(f), name, e, g))
                if verbose:
                    print(f"  DROP {os.path.basename(f)}: {name} input={e} output={g}")

    print("=== WGSL structural-drop sweep ===")
    print(f"  checked:        {checked}")
    print(f"  honest-refused: {refused}")
    print(f"  DROPS:          {len(drops)}")
    for name, kind, e, g in drops:
        print(f"    {name}: {kind} input={e} output={g}")
    return 1 if drops else 0


if __name__ == "__main__":
    sys.exit(main())
