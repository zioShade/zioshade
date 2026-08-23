#!/usr/bin/env python3
"""Detect a read of undefined Function-storage memory in a SPIR-V module.

A Function-storage OpVariable with NO Initializer operand holds an undefined
value until the first OpStore. WGSL has no uninitialized `var` (naga zero-
initializes every function-scope declaration), so the WGSL leg of a render
proxy CANNOT match a reference leg that leaves the variable undefined: the
reference renders whatever the GPU thread memory held (nondeterministic --
rendering the same spirv-cross MSL against itself differs on half the
frame), the WGSL leg renders a deterministic zero. No compiler output can
reconcile the two, so a differential oracle over such a source is invalid.

Detection mirrors src/spirv_lint.zig's emission-order heuristic (a read
whose store does not precede it in emission order; structured modules lay
dominators first, so textual order approximates dominance order). An
uninitialized Function variable is UNDEFINED-READING when a load reaches it
(directly, or through an OpAccessChain/OpInBoundsAccessChain rooted at it)
before any store to it -- or with no store anywhere -- AND BOTH of these
conservative exclusions hold:

  ESCAPE: the variable's pointer is never passed to a call (an out param
  the callee writes), handed to an ext-inst (modf's out slot), or otherwise
  used somewhere this scan cannot follow -- such a use may define it.

  CONTROL: the first read sits on the function's unconditional straight-line
  prefix, BEFORE the first control-flow instruction (OpBranchConditional,
  OpSwitch, OpLoopMerge, return/kill). A read guarded by a conditional can
  be correlated with the defining store through that guard
  (inside-loop-dominated-variable-preservation reads `v` only under a
  `written` flag the store sets first), so it is not provably undefined.

A miss (not flagged) keeps the historical verdict -- DIFFER stays loud and
gets baselined -- so both exclusions err away from skipping.

Usage: spv_undef_read.py <module.spv>
Prints the offending variable ids and exits 0 when found; exits 1 when the
module reads no undefined Function memory; exits 2 when the module cannot be
disassembled (caller treats that as no-skip, keeping the gate conservative).
"""

import re
import subprocess
import sys

VAR_RE = re.compile(r"^%(\w+) = OpVariable %(\w+) (\w+)(.*)$")
ACCESS_RE = re.compile(r"^%(\w+) = Op(?:InBounds)?AccessChain\b")
OPERANDS_RE = re.compile(r"%(\w+)")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: spv_undef_read.py <module.spv>", file=sys.stderr)
        return 2
    try:
        dis = subprocess.run(
            ["spirv-dis", sys.argv[1]], capture_output=True, text=True, check=True
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return 2

    uninit_vars: set[str] = set()  # Function vars with no initializer operand
    access_root: dict[str, str] = {}  # access-chain id -> uninit base var id
    escaped: set[str] = set()
    first_read: dict[str, int] = {}
    first_write: dict[str, int] = {}
    first_control: int | None = None  # first OpBranchConditional/Switch/LoopMerge/exit

    def root_of(ptr_id: str) -> str | None:
        seen = 0
        while ptr_id in access_root and seen < 64:
            ptr_id = access_root[ptr_id]
            seen += 1
        return ptr_id if ptr_id in uninit_vars else None

    for idx, raw in enumerate(dis.splitlines()):
        line = raw.split(";", 1)[0].strip()
        if first_control is None and (
            line.startswith("OpBranchConditional ")
            or line.startswith("OpSwitch ")
            or line.startswith("OpLoopMerge ")
            or line.startswith("OpReturn")
            or line.startswith("OpKill")
            or line.startswith("OpUnreachable")
        ):
            first_control = idx
        m = VAR_RE.match(line)
        if m and m.group(3) == "Function" and not m.group(4).strip():
            uninit_vars.add(m.group(1))
            continue
        m = ACCESS_RE.match(line)
        if m:
            # The base pointer is the first %id after the result type.
            operands = OPERANDS_RE.findall(line.split("=", 1)[1])
            if len(operands) >= 2:
                base = operands[1]
                seen = 0
                while base in access_root and seen < 64:
                    base = access_root[base]
                    seen += 1
                if base in uninit_vars:
                    access_root[m.group(1)] = base
            continue
        if line.startswith("OpStore "):
            target = OPERANDS_RE.findall(line[8:])
            if target:
                root = root_of(target[0])
                if root is not None and root not in first_write:
                    first_write[root] = idx
            # A pointer stored THROUGH a pointer-to-pointer escapes.
            for extra in target[1:]:
                root = root_of(extra)
                if root is not None:
                    escaped.add(root)
            continue
        if " = OpLoad " in line:
            operands = OPERANDS_RE.findall(line.split("= OpLoad ", 1)[1])
            # operands[0] is the result TYPE; operands[1] is the pointer.
            if len(operands) >= 2:
                root = root_of(operands[1])
                if root is not None and root not in first_read:
                    first_read[root] = idx
            continue
        # Any other mention (call argument, ext-inst out slot, phi, copy) is
        # a use this scan cannot follow: the var may be defined there.
        for operand in OPERANDS_RE.findall(line):
            if operand in uninit_vars:
                escaped.add(operand)

    bad = sorted(
        v
        for v in first_read
        if v not in escaped
        and first_read[v] < first_write.get(v, 1 << 60)
        and (first_control is None or first_read[v] < first_control)
    )
    if bad:
        print("undefined-read vars: " + " ".join("%" + v for v in bad))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
