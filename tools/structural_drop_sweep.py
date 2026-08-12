#!/usr/bin/env python3
"""Structural-drop detector for every backend.

A structural drop is the worst failure this compiler can have: a loop or a
switch present in the input SPIR-V is missing from the emitted source, the
output still compiles, and no validity gate can see it. The shader is silently
wrong.

This generalises `wgsl_structural_drop_sweep.py` (PR #582) to MSL, GLSL, HLSL
and WGSL, and runs over the CTS corpus as well as spirv-cross. That corpus
choice is the point. The 2026-07-28 control-flow-count sweep that certified
"loop-drop 0/279" for MSL/GLSL/HLSL ran only over `tests/spirv-cross`, whose
modules all come out of zioshade's own GLSL frontend. External SPIR-V reaches
block shapes the frontend never produces -- a loop nested inside a switch case
body among them -- and that is where the drops are.

Three independent signals, because each alone is blind somewhere:

  A. CROSS-BACKEND. Backend X emitted fewer loops (or switches) than EVERY
     other backend that compiled the same module. Independent implementations
     do not accidentally agree, so a lone dissenter that is strictly below all
     of its peers is a high-confidence drop. Strictly-below-all rather than
     below-the-max: some lowerings duplicate a loop body (MSL emits 7 for a
     3-loop module), and below-the-max would blame every peer of a duplicator.
     BLIND SPOT: a bug shared by two backends cancels out.

  B. SPIR-V LOWER BOUND. Backend X emitted fewer loops than the input requires.
     Raw OpLoopMerge counts are not that bound: a `do { } while(false)` is a
     structured goto and flattening it is correct. So provably single-iteration
     loops are subtracted first (see `flattenable_loops`). What remains is a
     genuine floor. BLIND SPOT: flattening this cannot prove stays subtracted,
     so B under-reports rather than crying wolf.

  C. WGSL NESTED-SELECTION SWITCH BREAKS. Ported verbatim from #582, which is
     the bug it was written to catch: four switch-breaks taken from inside a
     selection emitted as empty `if` bodies. It stays WGSL-only on purpose --
     WGSL switch cases do not fall through, so a case body's own exit needs no
     `break;`, while in the C-family backends it does. The counting rule is not
     portable and a mis-ported one is worse than none.

Only DROPS are reported. Extra constructs are not: lowering legitimately
introduces `loop`/`for` that the SPIR-V does not name one-for-one.

A shader a backend refuses is excluded from that backend's counts, on both
sides -- an honest error is a refusal, not a drop -- but it still participates
as a peer for the backends that did compile it.

Calibration, on the binary at af0f5e85:

  spirv-cross (1450 checked)  4 drops, all GLSL, all confirmed by hand
  CTS         (88 checked)    9 drops, all GLSL, all confirmed by hand
  MSL, HLSL, WGSL             0 across both corpora

So no signal has produced a false positive on 1538 shaders, and none has fired
on a backend other than the one with the known bug. `loop_in_case.frag` is the
clearest hit: a hand-written fixture whose own comment says GLSL should render
it, for which GLSL emits `case 0: { break; }` -- the entire `for` loop gone.

Usage:
    python3 tools/structural_drop_sweep.py [--corpus cts|spirv-cross|both]
                                           [--backends msl,glsl,hlsl,wgsl]
                                           [--verbose] [-j N]

Exit 1 if any signal fires.
"""

import argparse
import concurrent.futures
import glob
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.environ.get("ZIOSHADE_CLI") or os.path.join(ROOT, "zig-out/bin/zioshade")

ALL_BACKENDS = ("msl", "glsl", "hlsl", "wgsl")

LABEL_RE = re.compile(r"^\s*%(\w+) = OpLabel")
SWITCH_RE = re.compile(r"^\s*OpSwitch %\w+ %(\w+)((?:\s+\d+\s+%\w+)*)")
SEL_MERGE_RE = re.compile(r"^\s*OpSelectionMerge %(\w+)")
LOOP_MERGE_RE = re.compile(r"^\s*OpLoopMerge %(\w+) %(\w+)")
BRANCH_RE = re.compile(r"^\s*OpBranch %(\w+)\s*$")
BRANCH_COND_RE = re.compile(r"^\s*OpBranchConditional %(\w+) %(\w+) %(\w+)")


# --------------------------------------------------------------------------
# input side
# --------------------------------------------------------------------------


def flattenable_loops(lines):
    """Count OpLoopMerge loops that provably run at most one iteration.

    Those are structured gotos, not loops. GraphicsFuzz emits them constantly
    as `do { ... if (c) break; ... } while(false)`, and every backend is free
    to flatten one into a plain block. Counting them as required loops would
    bury the real drops in noise.

    Provable here means the continue target cannot reach the header again:
    either it branches straight to the merge, or its conditional back-edge is
    guarded by a literal false (resp. true, when the arms are swapped). Any
    loop whose back-edge depends on a runtime value is NOT counted, so this
    only ever subtracts loops it is certain about.
    """
    const_false, const_true = set(), set()
    for ln in lines:
        m = re.match(r"^\s*%(\w+) = OpConstantFalse", ln)
        if m:
            const_false.add(m.group(1))
        m = re.match(r"^\s*%(\w+) = OpConstantTrue", ln)
        if m:
            const_true.add(m.group(1))

    # terminator of each block, keyed by its label
    term = {}
    cur = None
    for ln in lines:
        lm = LABEL_RE.match(ln)
        if lm:
            cur = lm.group(1)
            continue
        if cur is None:
            continue
        s = ln.strip()
        if s.startswith(("OpBranch ", "OpBranchConditional ", "OpSwitch ", "OpReturn", "OpKill", "OpUnreachable")):
            term.setdefault(cur, s)

    count = 0
    for i, ln in enumerate(lines):
        lm = LOOP_MERGE_RE.match(ln)
        if not lm:
            continue
        merge, cont = lm.group(1), lm.group(2)
        t = term.get(cont)
        if t is None:
            continue
        if t == f"OpBranch %{merge}":
            count += 1
            continue
        bc = BRANCH_COND_RE.match(t)
        if not bc:
            continue
        cond, true_lbl, false_lbl = bc.group(1), bc.group(2), bc.group(3)
        # back-edge never taken
        if cond in const_false and false_lbl == merge:
            count += 1
        elif cond in const_true and true_lbl == merge:
            count += 1
    return count


def wgsl_nested_switch_breaks(lines):
    """Switch-breaks that WGSL must emit explicitly. Ported from #582.

    A branch to a switch's merge needs an explicit `break;` only when it is an
    early exit from inside a nested selection arm. Two other kinds of block
    branch there and need nothing: a case label itself (WGSL cases do not fall
    through, so the break is implicit) and a nested selection's merge block,
    which is the natural end of the case body. Without the second exclusion
    graphicsfuzz_037 reported two phantom drops.
    """
    breaks = 0
    arm_labels, merge_labels = set(), set()
    for ln in lines:
        bc = BRANCH_COND_RE.match(ln)
        if bc:
            arm_labels.add(bc.group(2))
            arm_labels.add(bc.group(3))
        sm = SEL_MERGE_RE.match(ln)
        if sm:
            merge_labels.add(sm.group(1))

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
    return breaks


def spirv_expectations(spv_path):
    """(loops_required, switches, wgsl_breaks) demanded by the input module."""
    try:
        dis = subprocess.run(["spirv-dis", spv_path], capture_output=True, text=True, timeout=60)
    except Exception:
        return None
    if dis.returncode != 0:
        return None
    lines = dis.stdout.splitlines()

    raw_loops = sum(1 for ln in lines if LOOP_MERGE_RE.match(ln))
    loops = raw_loops - flattenable_loops(lines)
    switches = sum(1 for ln in lines if re.match(r"^\s*OpSwitch ", ln))
    return max(0, loops), switches, wgsl_nested_switch_breaks(lines)


# --------------------------------------------------------------------------
# output side
# --------------------------------------------------------------------------


def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


def count_loops(src, backend):
    """Loop constructs in emitted source. `} while (...)` is a do-while tail,
    already counted at its `do {`, so it must not count twice."""
    src = strip_comments(src)
    if backend == "wgsl":
        return (
            len(re.findall(r"\bloop\s*\{", src))
            + len(re.findall(r"\bfor\s*\(", src))
            + len(re.findall(r"\bwhile\s+[^\{]*\{", src))
        )
    return (
        len(re.findall(r"\bfor\s*\(", src))
        + len(re.findall(r"(?<!\})\s\bwhile\s*\(", src))
        + len(re.findall(r"\bdo\s*\{", src))
    )


def count_switches(src, backend):
    src = strip_comments(src)
    if backend == "wgsl":
        return len(re.findall(r"\bswitch\s+[^\{]*\{", src))
    return len(re.findall(r"\bswitch\s*\(", src))


def count_wgsl_switch_breaks(src):
    """`break;` bound to a switch rather than to a loop. Ported from #582.

    In WGSL `break` binds to the nearest enclosing loop OR switch, and plain
    blocks between them (`default: {`, `if c {`) are transparent -- so scan
    DOWN the brace stack for the first loop/switch frame. Looking only at the
    top of the stack counted zero breaks for the very shader the sweep exists
    to catch.
    """
    breaks = 0
    stack = []  # innermost-last: "switch" | "loop" | "other"
    for raw in strip_comments(src).splitlines():
        if raw.strip().startswith("break;"):
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
    return breaks


# --------------------------------------------------------------------------
# sweep
# --------------------------------------------------------------------------


def analyse(path, backends, tmpdir, idx):
    """Per-shader worker. Returns a dict or None when nothing can be said."""
    # The module the backends consume is the one zioshade's frontend produces,
    # so a .frag has to be lowered first -- the expectations must be read from
    # that module, not from the GLSL text.
    spv = path
    if path.endswith(".frag"):
        spv = os.path.join(tmpdir, f"in{idx}.spv")
        c = subprocess.run([CLI, "compile", path, "-o", spv], capture_output=True, timeout=180)
        if c.returncode != 0:
            return None

    exp = spirv_expectations(spv)
    if exp is None:
        return None

    out = {"name": os.path.basename(path), "exp": exp, "counts": {}, "refused": []}
    for b in backends:
        p = subprocess.run([CLI, b, path], capture_output=True, text=True, timeout=180)
        if p.returncode != 0:
            out["refused"].append(b)
            continue
        out["counts"][b] = {
            "loops": count_loops(p.stdout, b),
            "switches": count_switches(p.stdout, b),
            "breaks": count_wgsl_switch_breaks(p.stdout) if b == "wgsl" else None,
        }
    return out


def evaluate(rec, backends):
    """Apply signals A, B and C to one shader.

    Returns one finding per (backend, construct), tagged with EVERY signal that
    fired. The signals are evaluated independently and not chained: an earlier
    `elif` here let A shadow B, which made B read as clean on a corpus where it
    was in fact agreeing with A on all four hits.
    """
    found = []
    exp_loops, exp_switches, exp_breaks = rec["exp"]
    counts = rec["counts"]

    for kind, key, exp in (("loop", "loops", exp_loops), ("switch", "switches", exp_switches)):
        vals = {b: c[key] for b, c in counts.items()}
        for b, v in sorted(vals.items()):
            sigs, want = [], exp
            peers = [x for k, x in vals.items() if k != b]
            # A: strictly below EVERY peer, and at least two peers to compare
            # against, so one broken peer cannot manufacture a finding.
            if len(peers) >= 2 and v < min(peers):
                sigs.append("A")
                want = max(want, min(peers))
            if v < exp:
                sigs.append("B")
            if sigs:
                found.append(("".join(sigs), b, kind, v, want))

    if "wgsl" in counts and counts["wgsl"]["breaks"] is not None:
        got = counts["wgsl"]["breaks"]
        if got < exp_breaks:
            found.append(("C", "wgsl", "switch-break", got, exp_breaks))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="both", choices=("cts", "spirv-cross", "both"))
    ap.add_argument("--backends", default=",".join(ALL_BACKENDS))
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("-j", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()

    backends = [b.strip() for b in args.backends.split(",") if b.strip()]
    for b in backends:
        if b not in ALL_BACKENDS:
            print(f"unknown backend: {b}", file=sys.stderr)
            return 2

    files = []
    if args.corpus in ("cts", "both"):
        files += sorted(glob.glob(os.path.join(ROOT, "tests/cts/graphicsfuzz/*.spv")))
    if args.corpus in ("spirv-cross", "both"):
        files += sorted(glob.glob(os.path.join(ROOT, "tests/spirv-cross/*.frag")))

    tmpdir = tempfile.mkdtemp()
    findings, checked, skipped = [], 0, 0
    refused = {b: 0 for b in backends}

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.j) as ex:
        futures = {ex.submit(analyse, f, backends, tmpdir, i): f for i, f in enumerate(files)}
        for fut in concurrent.futures.as_completed(futures):
            try:
                rec = fut.result()
            except Exception as e:
                print(f"  ERROR {os.path.basename(futures[fut])}: {e}", file=sys.stderr)
                skipped += 1
                continue
            if rec is None:
                skipped += 1
                continue
            checked += 1
            for b in rec["refused"]:
                refused[b] += 1
            for sig, b, kind, got, want in evaluate(rec, backends):
                findings.append((rec["name"], sig, b, kind, got, want))
                if args.verbose:
                    print(f"  [{sig}] {rec['name']}: {b} {kind} {got} < {want}")

    findings.sort(key=lambda f: (f[2], f[0], f[3]))

    print("=== structural-drop sweep ===")
    print(f"  corpus:   {args.corpus} ({len(files)} shaders)")
    print(f"  backends: {', '.join(backends)}")
    print(f"  checked:  {checked}   unusable: {skipped}")
    print("  honest-refused per backend: " + ", ".join(f"{b}={refused[b]}" for b in backends))
    print("  signals: A cross-backend  B SPIR-V floor  C WGSL nested-selection break")
    print(f"\n  DROPS: {len(findings)}")
    for name, sig, b, kind, got, want in findings:
        print(f"    [{sig:2s}] {name:28s} {b:5s} {kind:12s} emitted={got} expected={want}")
    per_backend = {b: sum(1 for f in findings if f[2] == b) for b in backends}
    print("\n  per backend: " + ", ".join(f"{b}={per_backend[b]}" for b in backends))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
