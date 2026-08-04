# Plan 002: Reject truncated SPIR-V instructions at parse time instead of panicking in the backends

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 0816eba..HEAD -- src/spirv_cross_common.zig src/spirv_to_glsl.zig src/spirv_to_hlsl.zig src/spirv_to_msl.zig src/spirv.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001-verification-baseline.md
- **Category**: security
- **Planned at**: commit `0816eba`, 2026-08-03

## Why this matters

zioshade is linked in-process by wintty, a GPU terminal emulator, and compiles
SPIR-V at startup. The SPIR-V binary parser validates that each instruction's
word count is non-zero and does not run past the end of the buffer, but it never
checks that an instruction is long enough to carry the operands its opcode
requires. A structurally valid module containing one short instruction (for
example a 3-word `OpAccessChain`, which the SPIR-V spec requires to be at least
4 words) is accepted, registered in the id table, and handed to a backend emit
switch that reads `inst.words[4..]` unconditionally.

In a safe build that is a Zig panic, which aborts the host terminal at startup.
In ReleaseFast it is an out-of-bounds read of adjacent heap memory. Either way a
malformed shader cache file or a corrupt SPIR-V blob takes down the host, which
is the opposite of the project's stated contract: an unfaithful input should
produce a loud error, not a crash.

**This is confirmed by reproduction, not inferred.** Against the CLI built from
commit `0816eba`, three truncated modules derived from real GraphicsFuzz
fixtures crash 11 of 12 backend/fixture combinations with SIGABRT (exit 134):

```
=== trunc_AccessChain_graphicsfuzz_000.spv ===
  glsl  rc=134 thread ... panic: index out of bounds: index 3, len 3
  msl   rc=1   error: cross-compilation failed: UndeclaredPrivateArrayGlobal
  hlsl  rc=134 thread ... panic: index out of bounds: index 3, len 3
  wgsl  rc=134 thread ... panic: index out of bounds: index 3, len 3
=== trunc_VectorShuffle_graphicsfuzz_001.spv ===
  glsl/msl/hlsl/wgsl  all rc=134  panic: index out of bounds: index 4, len 4
=== trunc_VectorShuffle_graphicsfuzz_002.spv ===
  glsl/msl/hlsl/wgsl  all rc=134  panic: index out of bounds: index 4, len 4
```

The one non-crash (MSL on the AccessChain case) reached a different honest error
first; it is not evidence that the MSL path is guarded, and MSL crashes on both
VectorShuffle cases.

The existing verification infrastructure does not cover this. The 5000-iteration
random-SPIR-V robustness runs mutate bytes rather than constructing a valid
module containing one deliberately short instruction, and `spirv-val` gates the
*output* side, not the input side. Note also that a module whose declared `bound`
exceeds its word count is rejected early by
`if (bound > words.len) return error.InvalidSpirv` at
`src/spirv_cross_common.zig:55`, so a naive hand-built test module gets rejected
for an unrelated reason. That is why the reproduction below truncates an
instruction inside an otherwise valid module.

## Current state

**The parser checks length but not per-opcode minimums.**
`src/spirv_cross_common.zig:41-81` (`pub fn parseModule`):

```zig
    if (words.len < 5) return error.InvalidSpirv;
    if (words[0] != spirv.MAGIC) return error.InvalidSpirvMagic;
    ...
    if (bound > words.len) return error.InvalidSpirv;
    const id_defs = try alloc.alloc(?usize, bound);
    @memset(id_defs, null);

    var i: usize = 5;
    while (i < words.len) {
        const header_word = words[i];
        const word_count: u16 = @intCast(header_word >> 16);
        const opcode: u16 = @truncate(header_word & 0xFFFF);

        if (word_count == 0) return error.InvalidSpirv;
        if (i + word_count > words.len) return error.InvalidSpirvTruncated;

        const op: spirv.Op = @enumFromInt(opcode);
        const inst_words = words[i .. i + word_count];

        if (resultIdFromOp(op, inst_words)) |id| {
            if (id < bound) id_defs[id] = instructions.items.len;
        }

        instructions.append(alloc, .{ .op = op, .words = inst_words }) catch
            return error.OutOfMemory;

        i += word_count;
    }
```

There is no check that `word_count` meets the opcode's spec-mandated minimum.

**There are four copies of this parser.** Verified by grep:

- `src/spirv_cross_common.zig:41` - `pub fn parseModule` (the shared one)
- `src/spirv_to_hlsl.zig:457` - private `fn parseModule`
- `src/spirv_to_glsl.zig:1937` - private `fn parseModule`
- `src/spirv_to_msl.zig:3656` - private `fn parseModule`

`src/spirv_to_wgsl.zig` has no copy; it delegates to `common` (see
`src/spirv_to_wgsl.zig:450`, `common.getDef(module, id)`). **All four copies
must get the check** or the backends that use their private copy stay exposed.

**Example of an unguarded consumer.** `src/spirv_to_glsl.zig:4777-4782`:

```zig
        .AccessChain => {
            const ri = inst.words[2];
            const bi = inst.words[3];
            const ex = try buildAccessExpr(m, names, bi, inst.words[4..], alloc);
            if (names.fetchPut(ri, ex) catch null) |old| alloc.free(old.value);
        },
```

`inst.words[2]`, `inst.words[3]` and the `[4..]` slice all assume a length the
parser never enforced. The same shape appears at `src/spirv_to_glsl.zig:5090-5106`
(`.VectorShuffle`, which additionally dereferences `vi.?.words[3]` on a
`TypeVector` def), `src/spirv_to_hlsl.zig:6332`, `src/spirv_to_msl.zig:8206`,
and `src/spirv_to_wgsl.zig:7804`. A mechanical scan counts roughly 96 emit arms
across the four backends that index `inst.words[>=3]` with no length guard.

**Do not try to fix the 96 call sites individually.** One validation at the
parser converts all of them at once. That is the entire point of this plan.

**The error type already exists.** `error.InvalidSpirvTruncated` is defined and
used at `src/spirv_cross_common.zig:66`. Reuse it rather than inventing a new one.

Repo conventions to match:

- The project's named contract is "honest error, never miscompile": when
  zioshade cannot faithfully translate something, it returns a loud error rather
  than emitting plausible-but-wrong output. Rejecting a malformed module with
  `error.InvalidSpirvTruncated` is exactly this contract, so an added rejection
  is a correct outcome, not a regression.
- Opcode names live in `src/spirv.zig` as the `spirv.Op` enum. Key the table on
  that enum, not on raw integers.
- Conventional-commit messages with a trailing PR number, for example
  `fix(spirv): reject instructions shorter than their opcode minimum (#NNN)`.
- **No AI attribution in commits**: do not add `Co-Authored-By` trailers.
- **Do not use em dashes** in code comments, commit messages, or docs.
- Zig 0.15.2 via mise; prefix builds with `mise exec --`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format check | `mise exec -- zig fmt --check src` | exit 0 |
| Unit tests | `mise exec -- zig build test` | exit 0, all pass |
| Strict gate | `mise exec -- zig build strict-gate` | exit 0, PASS 2108, XFAIL 13 |
| Conformance | `mise exec -- zig build conformance` | exit 0 |
| Backend fuzz | `mise exec -- zig build fuzz -- --count 5000` | exit 0, no crashes |
| CLI build | `mise exec -- zig build cli` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/spirv_cross_common.zig` - add the table and apply it in `parseModule`
- `src/spirv_to_hlsl.zig` - apply the check in the private `parseModule` at :457
- `src/spirv_to_glsl.zig` - apply the check in the private `parseModule` at :1937
- `src/spirv_to_msl.zig` - apply the check in the private `parseModule` at :3656
- `src/testdata/` - new negative fixtures (create)
- `tools/gen_truncated_fixtures.py` - the fixture generator (create)
- `tests/` - one new test file for the negative fixtures (create)

**Out of scope** (do NOT touch, even though they look related):
- The ~96 individual emit-switch arms. Adding per-arm length guards is the wrong
  fix, it multiplies the change by 96 and leaves the next new arm exposed.
  Fix it once at the parser.
- Consolidating the four `parseModule` copies into one. That is real debt and it
  is planned separately; doing it here mixes a security fix with a refactor and
  makes the diff unreviewable.
- `src/spirv_to_wgsl.zig` - it has no private parser, it already uses the shared
  one, so it is fixed for free by the change to `spirv_cross_common.zig`.
- `src/reflection.zig` - separate parse path, separate plan.
- The `toOwnedSlice(alloc) catch instructions.items` fallback visible at
  `src/spirv_cross_common.zig:81` and in the three copies. It is a real bug and
  it is covered by plan 005; do not fix it here.

## Git workflow

- Branch: `advisor/002-spirv-min-word-count`
- Commit per step, conventional-commit style, for example
  `fix(spirv): reject instructions shorter than their opcode minimum`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the minimum-word-count table

In `src/spirv_cross_common.zig`, add a function next to `parseModule`:

```zig
/// Minimum total word count (including the opcode/word-count header word) that
/// the SPIR-V spec requires for each opcode we model. Returns null for opcodes
/// with no fixed minimum beyond 1, which are accepted as-is.
fn minWordCount(op: spirv.Op) ?u16 { ... }
```

> **DO NOT HAND-TRANSCRIBE THIS TABLE.** A first attempt at this plan did exactly
> that and got 5 entries wrong in the unsafe direction, which made the compiler
> reject spec-valid SPIR-V it accepts today: `OpTypeStruct` was given 3 when the
> spec minimum is 2 (a zero-member struct is legal and is emitted by rust-gpu,
> Slang, and some spirv-opt output), and `OpRayQueryProceedKHR`,
> `OpRayQueryGetIntersectionTypeKHR`,
> `OpRayQueryGetIntersectionTriangleVertexPositionsKHR` and opcode 4432 were each
> given one word too many. The ray-query entries were self-contradictory:
> zioshade's own codegen emits a 4-word `OpRayQueryProceedKHR`
> (`src/codegen.zig:6296`), so the compiler would have rejected its own output.
>
> **Generate the table from the machine-readable grammar instead.** The rule is
> mechanical: `min = 1 + (number of operands with no quantifier)`, where a
> quantifier is `?` (optional) or `*` (variadic). Fetch
> `spirv.core.grammar.json` from KhronosGroup/SPIRV-Headers, emit the Zig switch
> with a small script committed as `tools/gen_min_word_count.py`, and record the
> upstream commit in a comment so it can be regenerated. If you cannot fetch the
> grammar file, STOP and report rather than hand-writing entries.
>
> Also note opcode 4432: `src/spirv.zig:232` names it `GroupNonUniformRotate`,
> but 4432 is actually `OpSubgroupReadInvocationKHR` (`OpGroupNonUniformRotateKHR`
> is 4431). Key the table on the numeric opcode from the grammar, not on
> zioshade's enum name, so an existing naming error cannot propagate into a
> validation rule. Report the mismatch; do not fix `spirv.zig` here.

Populate it from the SPIR-V specification for **the opcodes the backends
actually index into**. Derive that set mechanically rather than by hand:

```bash
grep -ohE '\.[A-Za-z]+ => \{' src/spirv_to_glsl.zig src/spirv_to_hlsl.zig \
  src/spirv_to_msl.zig src/spirv_to_wgsl.zig | sort -u
```

For each opcode in that set, the minimum is `1 + (number of fixed operands)`.
Worked examples to anchor the pattern:

- `OpAccessChain`: header + result type + result id + base = **4**
- `OpVectorShuffle`: header + result type + result id + vec1 + vec2 = **5**
- `OpFunctionCall`: header + result type + result id + function = **4**
- `OpVectorExtractDynamic`: header + result type + result id + vector + index = **5**
- `OpStore`: header + pointer + object = **3**
- `OpLoad`: header + result type + result id + pointer = **4**

Opcodes with variable trailing operands (for example `OpAccessChain`'s indices,
`OpVectorShuffle`'s components, `OpFunctionCall`'s arguments) have a *minimum*
that excludes the variable tail. That is exactly what the table encodes.

Do not attempt to cover all 251 modelled opcodes. Cover the emit-switch set plus
any opcode whose fixed operands the parser itself reads (see `resultIdFromOp`).
Anything not in the table returns null and is accepted, preserving today's
behavior for opcodes nothing indexes into.

**Verify**: `mise exec -- zig build test` -> exit 0 (no behavior change yet, the
table is not applied).

### Step 2: Apply the check in the shared parser

In `src/spirv_cross_common.zig:41-81`, immediately after the existing truncation
check, add:

```zig
        if (i + word_count > words.len) return error.InvalidSpirvTruncated;

        const op: spirv.Op = @enumFromInt(opcode);
        if (minWordCount(op)) |min| {
            if (word_count < min) return error.InvalidSpirvTruncated;
        }
```

Note the ordering: `op` must be computed before the new check, so move the
`const op` line up if needed. Keep the existing `word_count == 0` and buffer
overrun checks, they catch cases the table does not.

**Verify**:
- `mise exec -- zig build test` -> exit 0
- `mise exec -- zig build strict-gate` -> exit 0, still PASS 2108, XFAIL 13

If the strict gate count drops, a real fixture is being rejected. That is a STOP
condition, see below.

### Step 3: Apply the same check in the three private parser copies

Make `minWordCount` `pub` in `src/spirv_cross_common.zig` and apply the identical
two-line check in:

- `src/spirv_to_hlsl.zig:457` (private `parseModule`)
- `src/spirv_to_glsl.zig:1937` (private `parseModule`)
- `src/spirv_to_msl.zig:3656` (private `parseModule`)

Each of those files already imports the common module (they call `common.`
functions elsewhere). Call `common.minWordCount(op)`; do not copy the table.

**Verify**:
- `grep -c "minWordCount" src/spirv_to_hlsl.zig src/spirv_to_glsl.zig src/spirv_to_msl.zig src/spirv_cross_common.zig`
  -> each file returns at least 1
- `mise exec -- zig build strict-gate` -> exit 0, PASS 2108, XFAIL 13

### Step 4: Add negative fixtures

Create hand-built `.spv` binaries under `src/testdata/`, each a minimal valid
module header (magic, version, generator, bound, schema) followed by one
deliberately truncated instruction. Follow the existing naming pattern in that
directory: `src/testdata/hostile_garbage.spv` and
`src/testdata/hostile_crash_hlsl.spv` are already there.

**Do not hand-build a module from scratch.** A module whose declared `bound`
exceeds its word count is rejected early by
`if (bound > words.len) return error.InvalidSpirv` (`src/spirv_cross_common.zig:55`),
and a module with no entry point is rejected before any emit arm is reached, so
a naive hand-built fixture never exercises the defect. Instead, truncate an
instruction **inside an otherwise valid module**, deleting the dropped operand
words so the instruction stream stays aligned.

This generator is verified to produce crashing fixtures against commit `0816eba`.
Save it as `tools/gen_truncated_fixtures.py` (a `tools/` script is in scope for
this step) so the fixtures can be regenerated:

```python
import struct, glob, os
OUT = "src/testdata"
# opcodes whose emit arms index words[>=3], with their spec minimum word count
TARGETS = {65: ("AccessChain", 4), 79: ("VectorShuffle", 5), 61: ("Load", 4)}
for path in sorted(glob.glob("tests/cts/graphicsfuzz/*.spv"))[:40]:
    w = list(struct.unpack("<%dI" % (os.path.getsize(path) // 4), open(path, "rb").read()))
    if w[0] != 0x07230203:
        continue
    i = 5
    while i < len(w):
        wc = w[i] >> 16
        op = w[i] & 0xFFFF
        if wc == 0:
            break
        if op in TARGETS:
            name, minwc = TARGETS[op]
            if wc > minwc:                      # has droppable trailing operands
                newwc = minwc - 1               # one word SHORTER than the minimum
                out = w[:i] + [(newwc << 16) | op] + w[i+1:i+newwc] + w[i+wc:]
                fn = "%s/truncated_%s.spv" % (OUT, name.lower())
                open(fn, "wb").write(b"".join(struct.pack("<I", x) for x in out))
                break
        i += wc
```

Produce at least `truncated_accesschain.spv` and `truncated_vectorshuffle.spv`.
Follow the naming style already in that directory
(`src/testdata/hostile_garbage.spv`, `src/testdata/hostile_crash_hlsl.spv`).

**Verify**: before your parser change, each fixture crashes the CLI:
`./zig-out/bin/zioshade glsl src/testdata/truncated_vectorshuffle.spv -o /dev/null; echo $?`
-> **134** with an "index out of bounds" panic. After the fix it must exit
non-zero with `InvalidSpirvTruncated` and no panic. Record both outcomes.

### Step 5: Assert the fixtures produce an honest error on all four backends

Create `tests/truncated_spirv_tests.zig`. For each fixture and each of the four
backends (GLSL, HLSL, MSL, WGSL), assert the call returns
`error.InvalidSpirvTruncated` and does **not** panic.

Model the file structure on `tests/optimizer_tests.zig` (test-block style,
allocator handling, how it loads `.spv` bytes). Wire the new file into the test
build the same way the existing `tests/*.zig` files are wired in `build.zig`,
following whatever pattern `tests/optimizer_tests.zig` uses.

Use `std.testing.expectError(error.InvalidSpirvTruncated, ...)`.

**Verify**: `mise exec -- zig build test` -> exit 0, and the new tests appear in
the output (12 new assertions: 3 fixtures x 4 backends).

### Step 6: Run the full gate

**Verify**: all of the following exit 0:
- `mise exec -- zig fmt --check src`
- `mise exec -- zig build test`
- `mise exec -- zig build strict-gate` (PASS 2108, XFAIL 13, unchanged)
- `mise exec -- zig build conformance`
- `mise exec -- zig build fuzz -- --count 5000`

## Test plan

- New file `tests/truncated_spirv_tests.zig`, structured like
  `tests/optimizer_tests.zig`.
- Cases: 3 truncated fixtures x 4 backends = 12 assertions, each expecting
  `error.InvalidSpirvTruncated`.
- One positive control: a well-formed fixture from `tests/fixtures/` still
  compiles successfully through at least one backend, proving the new check does
  not reject valid input.
- **A corpus-wide floor assertion. This is the test that actually protects
  against an over-strict table, and it is mandatory.** Walk every `.spv` file
  under `tests/` and `src/testdata/` (excluding the deliberately-truncated
  fixtures this plan adds) and assert, for every instruction in every module,
  that `minWordCount(op) <= actual word_count`. A single over-strict entry fails
  this immediately, with the offending opcode named.

> **Do NOT rely on the strict gate to catch an over-strict table. It cannot.**
> A previous attempt claimed "strict gate unchanged" as its regression proof, and
> that claim was true but vacuous: `strictGateDir` (`tests/runner.zig:451-557`)
> only calls `zioshade.compileToSPIRV`, the GLSL frontend, and none of the four
> `parseModule` copies is reachable from that path. `zig build conformance` is no
> better, since its corpus is glslang/zioshade-frontend derived and contains
> neither empty structs nor ray query. The corpus floor assertion above is the
> real check. Keep running the strict gate, but understand it is proving the
> frontend did not regress, not that the table is safe.

**Verification**: `mise exec -- zig build test` -> all pass, 13 new assertions.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `mise exec -- zig fmt --check src` exits 0
- [ ] `mise exec -- zig build test` exits 0, `tests/truncated_spirv_tests.zig`
      exists and its tests pass
- [ ] `mise exec -- zig build strict-gate` exits 0 and still reports PASS 2108,
      XFAIL 13 (identical to before this plan)
- [ ] `mise exec -- zig build conformance` exits 0
- [ ] `mise exec -- zig build fuzz -- --count 5000` exits 0
- [ ] All four parser sites call the shared check:
      `grep -c minWordCount src/spirv_cross_common.zig src/spirv_to_glsl.zig src/spirv_to_hlsl.zig src/spirv_to_msl.zig`
      returns a non-zero count for each
- [ ] `grep -rn "fn minWordCount" src/` returns exactly one definition
- [ ] No files outside the in-scope list are modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpt at `src/spirv_cross_common.zig:41-81` does not match the code.
- **The strict gate count drops below PASS 2108 after step 2 or step 3.** This
  means a real fixture contains an instruction shorter than your table says it
  should be. Do NOT relax the table to make the gate green. Report which fixture
  and which opcode: either the table entry is wrong (fix that specific entry
  against the SPIR-V spec) or a real fixture is malformed (a genuine finding).
  Getting this backwards would weaken the check to fit bad data.
- You cannot determine an opcode's spec minimum with confidence. Omit that
  opcode from the table (null is safe, it preserves today's behavior) and list
  the omissions in your report rather than guessing.
- Any backend already fails to build because a private `parseModule` has a
  materially different structure from the shared one.
- The fuzz run reports a crash that did not occur before your change.

## Maintenance notes

- **The table is the single choke point for input validation.** When a new
  opcode arm is added to any emit switch, its minimum belongs in
  `minWordCount`. A reviewer should ask for the table entry whenever a PR adds
  an opcode arm that indexes `inst.words[>=3]`.
- The four duplicated `parseModule` copies are the reason this plan touches four
  files instead of one. Consolidating them onto `common.parseModule` is tracked
  separately and would make this class of fix a one-line change in future.
- This plan validates *length* only. Operand-level validity (an id that exceeds
  the bound, a type id that names a non-type) is a separate and larger class,
  deliberately not covered here. The parser does already clamp id registration
  with `if (id < bound)`, so out-of-range result ids are handled.
- Deliberately deferred: extending the negative-fixture corpus to one truncated
  case per table entry. Three representative fixtures prove the mechanism; a
  generated exhaustive corpus is a good follow-up once the table stabilizes.
