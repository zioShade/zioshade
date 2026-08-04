# Plan 005: Stop optimizer passes and module parsers from swallowing allocation failures

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 0816eba..HEAD -- src/compact_ids_passes.zig src/spirv_cross_common.zig src/spirv_to_glsl.zig src/spirv_to_hlsl.zig src/spirv_to_msl.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001-verification-baseline.md
- **Category**: bug
- **Planned at**: commit `0816eba`, 2026-08-03

## Why this matters

This project's named contract is "honest error, never miscompile": when it
cannot faithfully translate something it returns a loud error rather than
emitting plausible-but-wrong output. Several optimizer passes violate that
contract under memory pressure. When an append fails, the pass silently drops
the item and keeps going, so an `OpVariable` declaration or a pending edit
vanishes from the module being rewritten. The result is SPIR-V that references
undeclared ids, returned at exit 0 as if nothing happened. That is a silent
miscompile produced by the compiler's own error handling.

The same file also leaks on early-return paths: several `catch return words`
sites abandon two live `ArrayList`s with no `defer deinit` covering them, in a
library that is linked in-process and may compile many shaders per run.

A related defect sits in all four module parsers: `toOwnedSlice(alloc) catch
instructions.items` hands back the `ArrayList`'s backing buffer, whose capacity
is larger than `items.len`, and the matching `deinit` then frees a slice of the
wrong length. With the `DebugAllocator` the C ABI uses, that trips a safety
assertion and aborts the host process.

All of these are OOM-gated and therefore rare, but they are memory-safety and
silent-correctness bugs in the two code paths every single compile runs through.

## Current state

**Silent drops in the optimizer.** `src/compact_ids_passes.zig:1542-1557`:

```zig
                if (bop == 248) break; // next block
                if (bop == 59) { // OpVariable
                    var_list.appendSlice(alloc, words[bp .. bp + bwc]) catch {};
                }
                // Stop at the block terminator.
                if (bop == 249 or bop == 250 or bop == 251 or bop == 253 or
                    bop == 254 or bop == 252 or bop == 255)
                {
                    break;
                }
                bp += bwc;
            }
            const var_words = var_list.toOwnedSlice(alloc) catch &.{};
            edits.append(alloc, .{ .entry_label = entry_label, .new_label = bound, .var_words = var_words }) catch {};
            bound += 1;
```

Three defects in sixteen lines: the `appendSlice ... catch {}` drops an
`OpVariable` from the block being rewritten; the `toOwnedSlice ... catch &.{}`
discards the whole collected list *and leaks it*; the `edits.append ... catch {}`
drops the edit *and leaks* `var_words`.

**Leaks on early return.** `src/compact_ids_passes.zig:2219-2231` has
`fixed.append(alloc, ...) catch return words;` and
`const nw = result.toOwnedSlice(alloc) catch return words;`. Neither `result`
nor `fixed` has a `defer deinit`; `result` is only deinitialised on the success
path at line 2227.

**Scale of the pattern.** `src/compact_ids_passes.zig` contains 72 occurrences
of `catch {}`. **Not all of them are bugs.** Many are deliberately best-effort
(diagnostics, name prettification) where dropping the work is the correct
behavior. Only the sites that mutate the emitted word stream matter. This plan
is scoped to those.

**Wrong-length free in all four parsers.** `src/spirv_cross_common.zig:81`:

```zig
    const owned_instructions = instructions.toOwnedSlice(alloc) catch instructions.items;
```

`ParsedModule.deinit` (`src/spirv_cross_common.zig:32-38`) then frees
`bytes[0..self.instructions.len]`. When `toOwnedSlice` fails, `items` still has
the larger backing capacity, so the free length is wrong.

The identical line exists in all four parser copies, verified by grep:

- `src/spirv_cross_common.zig:81`
- `src/spirv_to_hlsl.zig:496`
- `src/spirv_to_glsl.zig:1964`
- `src/spirv_to_msl.zig:3683`

**Passes already return error unions.** Every pass in
`src/compact_ids_passes.zig` has the signature
`fn (alloc, words: []const u32) ![]const u32`, so propagating an error needs no
signature change. The callers in `src/codegen.zig:239-418` already handle a
failing pass with `catch prev`, meaning a propagated OOM degrades to "skip this
pass and keep the previous module", which is correct and safe.

Repo conventions to match:

- Optimizer passes are pure functions over the raw SPIR-V word stream. They take
  an allocator and return a newly allocated module or an error.
- `tests/optimizer_tests.zig` (872 lines) is the existing test file for this
  layer. Follow its structure.
- Conventional-commit messages with a trailing PR number.
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
| Fuzz | `mise exec -- zig build fuzz -- --count 5000` | exit 0, no crashes |

## Scope

**In scope** (the only files you should modify):
- `src/compact_ids_passes.zig` - only the word-stream-mutating sites listed in
  step 1
- `src/spirv_cross_common.zig` - the `toOwnedSlice` fallback at :81
- `src/spirv_to_hlsl.zig` - the `toOwnedSlice` fallback at :496
- `src/spirv_to_glsl.zig` - the `toOwnedSlice` fallback at :1964
- `src/spirv_to_msl.zig` - the `toOwnedSlice` fallback at :3683
- `tests/optimizer_tests.zig` - add the allocation-failure test

**Out of scope** (do NOT touch, even though they look related):
- **The other ~68 `catch {}` sites in `src/compact_ids_passes.zig`, and the
  `catch {}` sites in `src/spirv_to_msl.zig` (75) and `src/semantic.zig` (58).**
  Many are deliberately best-effort. Converting them wholesale would turn
  cosmetic failures into hard errors and is a much larger judgment-heavy change.
  This plan fixes only sites that can corrupt the emitted module.
- `src/root.zig:1024` and `:1044` (`compact_ids.compactIds(...) catch return
  result`, `kernel_fusion.fuseKernels(...) catch return spirv_words`). Those
  swallow a *whole pass* failure, which is a different and more debatable
  decision. Noted in the backlog.
- Consolidating the four duplicated parsers. Separate concern, separate plan.
- Any change to which passes run or their order in `src/codegen.zig:239-418`.
  The pipeline ordering is empirically tuned and load-bearing.

## Git workflow

- Branch: `advisor/005-optimizer-alloc-discipline`
- Commit per step, conventional-commit style, for example
  `fix(opt): propagate allocation failures instead of dropping module edits`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix the word-stream-mutating sites in the optimizer

Find the sites to fix mechanically:

```bash
grep -n "catch {}\|catch &\.{}\|catch return words" src/compact_ids_passes.zig
```

For each hit, decide by this rule and no other:

- **Does dropping this call change the bytes of the module the pass emits?**
  If yes, it is in scope: convert it to `try`. If it only affects a name, a
  debug string, or a diagnostic, leave it alone.

Known in-scope sites, confirmed by reading:

- `src/compact_ids_passes.zig:1544` - `var_list.appendSlice(...) catch {}`
- `src/compact_ids_passes.zig:1554` - `var_list.toOwnedSlice(...) catch &.{}`
- `src/compact_ids_passes.zig:1555` - `edits.append(...) catch {}`
- `src/compact_ids_passes.zig:2219` - `fixed.append(...) catch return words`
- `src/compact_ids_passes.zig:2223` - the paired site in the same block
- `src/compact_ids_passes.zig:2231` - `result.toOwnedSlice(...) catch return words`

Convert each to `try`. The enclosing functions already return `![]const u32`, so
no signature changes are needed.

While you are in each function, add `defer`/`errdefer` `deinit` for every
`ArrayList` that lacks one, so the newly propagating errors do not leak. In the
`:2219-2231` block specifically, both `result` and `fixed` need coverage: today
`result` is only deinitialised on the success path at `:2227`.

List every site you changed and every site you deliberately skipped, with the
one-line reason, in your final report.

**Verify**:
- `mise exec -- zig build test` -> exit 0
- `mise exec -- zig build strict-gate` -> exit 0, PASS 2108, XFAIL 13
- `mise exec -- zig build conformance` -> exit 0

The strict gate must be **byte-identical** in outcome. These changes only alter
behavior under allocation failure, which does not occur in a normal run. Any
change to the gate's numbers means you changed a success path by mistake.

### Step 2: Fix the wrong-length free in all four parsers

Replace the fallback in each of the four parsers:

```zig
    const owned_instructions = instructions.toOwnedSlice(alloc) catch return error.OutOfMemory;
```

Sites:
- `src/spirv_cross_common.zig:81`
- `src/spirv_to_hlsl.zig:496`
- `src/spirv_to_glsl.zig:1964`
- `src/spirv_to_msl.zig:3683`

(The local variable name differs between copies: `owned_instructions` in two,
`owned` in the others. Keep whatever name is already there.)

All four `parseModule` functions already return `!ParsedModule`, so this
propagates cleanly, and all four callers already handle a parse error.

Check for a matching leak: if the function has allocated `id_defs` (see
`src/spirv_cross_common.zig:56`) before this point, the new early return must
not leak it. Add `errdefer alloc.free(id_defs)` after that allocation in each
copy if one is not already present.

**Verify**:
- `grep -n "toOwnedSlice(alloc) catch instructions.items\|toOwnedSlice(alloc) catch items" src/`
  -> no matches
- `mise exec -- zig build test` -> exit 0
- `mise exec -- zig build strict-gate` -> exit 0, PASS 2108, XFAIL 13

### Step 3: Add an allocation-failure test

> **Put this test INSIDE `src/`, as an inline `test` block in
> `src/compact_ids_passes.zig`, not in `tests/optimizer_tests.zig`.** A first
> attempt at this plan tried the `tests/` route, discovered the pass functions
> are not reachable from there, and added `pub const compact_ids_passes` and
> `pub const spirv_cross_common` re-exports to `src/root.zig` to make them
> visible. That is a scope violation and, worse, it permanently widens the
> library's public API surface (this repo makes a SemVer promise on what
> `src/root.zig` exports, `CHANGELOG.md:3`) purely to enable a test. An inline
> test block sits next to the code, needs no re-export, and runs under the same
> `zig build test`. `src/semantic.zig` already carries 54 inline tests, so this
> matches existing convention.
>
> **`src/root.zig` is NOT in scope. Do not add re-exports to it.**

Add an inline `test` block using `std.testing.checkAllAllocationFailures`, which
runs the target repeatedly with each successive allocation forced to fail and
asserts no leaks.

Cover:

1. One representative pass from the `:1542-1557` block (the one containing the
   `var_list`/`edits` code) over a small hand-built SPIR-V module.
2. `common.parseModule` over a small valid module.

The assertion that matters is twofold: the call either succeeds or returns
`error.OutOfMemory`, and nothing leaks. It must never return a *successfully
transformed but incomplete* module.

Follow the existing test-block style and module-construction helpers already in
`tests/optimizer_tests.zig`; reuse whatever helper that file uses to build a
minimal module rather than writing a new one.

**Verify**: `mise exec -- zig build test` -> exit 0, 2 new tests pass.

Confirm the test has teeth: stash step 1 and step 2 (`git stash`), run the new
tests, and expect a leak report or an incomplete-module assertion failure. Then
`git stash pop`. Record both outcomes in your report. If the tests pass against
the unfixed code, they are not exercising the defects.

### Step 4: Run the full gate

**Verify**: all of the following exit 0:
- `mise exec -- zig fmt --check src`
- `mise exec -- zig build test`
- `mise exec -- zig build strict-gate` (PASS 2108, XFAIL 13, unchanged)
- `mise exec -- zig build conformance`
- `mise exec -- zig build fuzz -- --count 5000`

## Test plan

- Two new tests in `tests/optimizer_tests.zig` using
  `std.testing.checkAllAllocationFailures`, as described in step 3.
- Structural pattern: the existing tests in that same file.
- The strict gate and conformance run are the regression protection for the
  success path: both must be unchanged, since none of these edits should alter
  behavior when allocation succeeds.

**Verification**: `mise exec -- zig build test` -> all pass, 2 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `mise exec -- zig fmt --check src` exits 0
- [ ] `mise exec -- zig build test` exits 0, including 2 new
      allocation-failure tests
- [ ] `mise exec -- zig build strict-gate` exits 0, PASS 2108, XFAIL 13
      (identical to before this plan)
- [ ] `mise exec -- zig build conformance` exits 0
- [ ] `mise exec -- zig build fuzz -- --count 5000` exits 0
- [ ] `grep -rn "toOwnedSlice(alloc) catch instructions.items" src/` returns no
      matches
- [ ] `grep -n "catch {}" src/compact_ids_passes.zig | wc -l` returns a number
      strictly less than 72
- [ ] The report lists every changed site and every deliberately skipped site
- [ ] No files outside the in-scope list are modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts at `src/compact_ids_passes.zig:1542-1557` or `:2219-2231`, or the
  `toOwnedSlice` line in any of the four parsers, do not match the live code.
- **The strict gate count changes at any step.** These edits must not alter
  success-path behavior. A changed count means a success path was modified;
  revert that specific edit and report.
- Converting a site to `try` requires changing a function signature. The passes
  are supposed to already return error unions; a site that needs a signature
  change is either out of scope or a sign you are editing something other than a
  pass. Report it.
- You cannot confidently decide whether a `catch {}` site affects emitted bytes.
  Leave it alone and list it in your report as needing maintainer judgment.
  Skipping a site is safe; converting a best-effort site to a hard error is not.
- `std.testing.checkAllAllocationFailures` is unavailable or behaves differently
  on the pinned Zig 0.15.2. Write the test with a manual failing-allocator
  wrapper instead, or report and stop if that also proves difficult.
- The new tests pass against the unfixed code (step 3 stash check).

## Maintenance notes

- **The rule for reviewers**: in a pass that rewrites the word stream, `catch {}`
  on an append is a silent miscompile waiting to happen. Best-effort error
  handling is fine for names and diagnostics, never for emitted bytes. Worth
  stating in `CONTRIBUTING.md` if this recurs.
- Roughly 68 `catch {}` sites remain in `src/compact_ids_passes.zig` plus more in
  `src/spirv_to_msl.zig` and `src/semantic.zig`. They were deliberately left
  alone. A future sweep should classify them the same way (does it affect
  emitted bytes?) rather than converting them wholesale.
- `src/root.zig:1024` and `:1044` swallow whole-pass failures with
  `catch return result` / `catch return spirv_words`, so a failing pass is
  indistinguishable from one that legitimately no-ops. That is a defensible
  design (a failed optimization degrades to unoptimized output) but it is
  currently silent. Making it observable, at minimum a debug log, is a good
  follow-up and is deliberately not in this plan.
- The four duplicated parsers are why step 2 touches four files. Consolidation is
  tracked separately.
