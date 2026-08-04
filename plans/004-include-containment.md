# Plan 004: Contain `#include` resolution to configured roots and key cycle detection on the resolved path

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 0816eba..HEAD -- src/preprocessor.zig`
> If the file changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as
> a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001-verification-baseline.md
- **Category**: security
- **Planned at**: commit `0816eba`, 2026-08-03

## Why this matters

Shader source is untrusted input for this project's primary consumer. wintty is
a GPU terminal emulator whose users routinely copy ricing shaders off the
internet and load them. The preprocessor resolves `#include` by concatenating
the include token straight onto a directory prefix with no normalization, no
rejection of `..`, and no check that the result stays under the source directory
or a configured `-I` root. A shader containing a traversal include therefore
reads an arbitrary file the process can open into the translation unit, whose
bytes then surface through compiler diagnostics or emitted backend source. That
is an arbitrary-file-read primitive driven entirely by a shader file.

A second defect sits in the same function. Cycle detection is keyed on the raw
include *token text* rather than the resolved path, which produces two silent
wrong outcomes: every include becomes implicitly include-once even without
`#pragma once` (a header legitimately included twice is silently dropped, so the
compile succeeds with missing declarations), and two genuinely different files
that share a relative spelling under different `-I` roots collide. Both are
silent-wrong, which is precisely the failure class this project's contract
forbids.

The two fixes belong together because both need the resolved path.

## Current state

The file is `src/preprocessor.zig`. The relevant function is the include
resolver (the code shown below sits around lines 430-465).

**Resolution has no containment.** `src/preprocessor.zig:430-463`:

```zig
        // Filesystem-backed include resolution. Freestanding targets (the wasm
        // playground) have no std.fs/std.posix, so we compile these branches out
        // there: on wasm, includes must come through the `file_reader` callback
        // above, not from disk. Everywhere else the disk fallbacks stay.
        if (builtin.os.tag != .freestanding) {
            // Try relative to source file
            if (!is_system and self.source_file_path.len > 0) {
                var dir_end = self.source_file_path.len;
                while (dir_end > 0 and self.source_file_path[dir_end - 1] != '/' and self.source_file_path[dir_end - 1] != '\\') dir_end -= 1;
                const dir_part = self.source_file_path[0..dir_end];

                var full_path_buf: [4096]u8 = undefined;
                const full_path = std.fmt.bufPrintZ(&full_path_buf, "{s}{s}", .{ dir_part, path }) catch return error.FileNotFound;

                const raw = compat.readFileByPath(self.alloc, full_path, 10 * 1024 * 1024) catch return error.FileNotFound;
                // Null-terminate for lexer
                const z = try self.alloc.dupeZ(u8, raw);
                self.alloc.free(raw);
                try self.included_sources.append(self.alloc, z);
                return z;
            }

            // Try include paths
            for (self.include_paths) |inc_path| {
                var full_path_buf: [4096]u8 = undefined;
                const full_path = std.fmt.bufPrintZ(&full_path_buf, "{s}/{s}", .{ inc_path, path }) catch continue;

                const raw = compat.readFileByPath(self.alloc, full_path, 10 * 1024 * 1024) catch continue;
                const z = try self.alloc.dupeZ(u8, raw);
                self.alloc.free(raw);
                try self.included_sources.append(self.alloc, z);
                return z;
            }
        }
```

`path` is the raw token text taken verbatim from the source at
`src/preprocessor.zig:196-215`, and reaches this function via
`src/preprocessor.zig:225`. Note the `"{s}{s}"` form in the first branch: a
`path` beginning with `/` produces an absolute path outright.

**Cycle detection is keyed on the unresolved token.**
`src/preprocessor.zig:230-236`:

```zig

        // Check for cycles
        if (self.included_files.contains(path)) return;

        // Check #pragma once - skip if file was already included with #pragma once
        if (self.pragma_once_files.contains(path)) return;

```

and the insertion at `src/preprocessor.zig:252-254` stores the same unresolved
string: `try self.included_files.put(self.alloc, path_copy, {});`

The presence of a *separate* `pragma_once_files` set (checked immediately after,
and populated by the `#pragma once` handling at `src/preprocessor.zig:389`)
shows the intent: include-once is meant to be opt-in via the pragma. The
`included_files` check makes it unconditional, which defeats the pragma's
purpose and deviates from C and GLSL `#include` semantics.

Repo conventions to match:

- The project's contract is "honest error, never miscompile". A rejected include
  must produce a clear error, not a silent skip. Existing error values in this
  file include `error.FileNotFound`; add a distinct error for a refused path so
  the two are distinguishable in diagnostics.
- Diagnostics carry `path:line:col` (see the CLI diagnostic work in commit
  `00a909a`). A refusal message should name the offending include.
- The freestanding (wasm) branch must keep compiling: `builtin.os.tag !=
  .freestanding` guards all filesystem access, and on wasm includes come through
  the `file_reader` callback. **Any path helper you add must not pull
  `std.fs`/`std.posix` into the freestanding build.** Put new filesystem-touching
  code inside the existing `if (builtin.os.tag != .freestanding)` block, or
  guard it the same way.
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
| WASM build | `mise exec -- zig build wasm` | exit 0 (proves freestanding still compiles) |
| CLI | `mise exec -- zig build cli` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/preprocessor.zig`
- `tests/` - one new test file for include resolution (create)
- `tests/fixtures/` or a new test-local directory for include fixtures (create)

**Scope amendment (2026-08-03, after a first attempt hit the STOP condition
below).** `src/compat.zig` is now **IN SCOPE, but only** to add a
`realpath`-equivalent shim that works on both Zig 0.15.2 and 0.16. That file
exists precisely to centralize dual-version churn, so a path-canonicalization
shim belongs there rather than being a reason to abandon the plan. Keep the
addition minimal: one function plus whatever version switch the file already
uses (`src/compat.zig:113` shows the `is_0_16` pattern). Do not refactor
anything else in that file.

If canonicalization still proves unworkable on both versions, fall back to
**pure lexical containment**: normalize the path by resolving `.` and `..`
components textually, then require the result to stay under the root. State
clearly in your report that the symlink-escape case is then NOT covered, and
leave the symlink test skipped with that reason. Lexical containment plus the
step 1 spelling check still closes the traversal hole, which is the finding;
symlink escape is the smaller residual.

**SCOPE SPLIT (2026-08-04, after round 2 review). STEP 3 IS NOW OUT OF SCOPE.**

Round 2 implemented the whole plan and review found that **step 3 introduces two
regressions worse than the bug it fixes**, both reproduced:

1. `#pragma once` stopped short-circuiting before I/O. Because the check is now
   keyed on the resolved path, `resolve()` (which reads the file, `dupeZ`s it,
   and appends to `included_sources`) runs at `src/preprocessor.zig:269` BEFORE
   the `pragma_once_files.contains(key)` check at `:299`. The early return never
   pops the appended copy, so a repeatedly included guarded header is re-read and
   **permanently retained once per textual occurrence**.
2. Restoring correct double-inclusion makes expansion exponential in depth with
   no budget. A probe of 7 files each including the next twice produced 127 reads
   and 127 retained copies; with `max_include_depth` at 16
   (`src/preprocessor.zig:35`) the worst case is 65535 reads and 65535 retained
   copies, each capped at 10 MiB. The accidental include-once behavior was
   bounding this.

**This plan is now containment only: steps 1, 2, 4 and 5.** Do NOT change the
cycle-detection keying or the `included_files` set. Leave the accidental
include-once semantics exactly as they are on `main`. Drop the two
double-inclusion test cases from step 4; keep every containment test.

The security finding (a shader file reading arbitrary paths) is closed entirely
by containment. The `#include` semantics deviation is a separate, lower-severity
correctness issue and is recorded in the backlog in `plans/README.md`; it needs an
expansion budget designed in from the start, modelled on the macro-expansion
budget this repo already has, and that is its own plan.

**Out of scope** (do NOT touch, even though they look related):
- **Step 3's cycle-detection re-keying and anything touching `included_files` or
  `pragma_once_files`.** See the scope split above. This is the single most
  important boundary in this plan now.
- The `file_reader` callback path used by wasm. It is host-supplied and the host
  owns its own policy; containment there is the embedder's responsibility.
- `src/lexer.zig` and the include-token tokenization at
  `src/preprocessor.zig:196-215`. The token text is fine; the handling is what
  changes.
- `src/cli.zig` - do not add a new CLI flag for this. The `-I` roots already
  express the allowed set.
- Macro expansion, `#pragma` handling other than the `pragma_once_files` set,
  and conditional-compilation logic.

## Git workflow

- Branch: `advisor/004-include-containment`
- Commit per step, conventional-commit style, for example
  `fix(preprocessor): contain #include resolution to the source dir and -I roots`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reject traversal and absolute includes up front

Add a validation helper in `src/preprocessor.zig` that inspects the raw include
token **before** any path is built:

```zig
/// An include spelling is refused outright when it can escape the include
/// roots by construction. This runs before any filesystem access.
fn includeSpellingIsSafe(path: []const u8) bool { ... }
```

Refuse when the token:

- is empty,
- is absolute: begins with `/` or `\`, or matches a Windows drive form such as
  `C:` (an alphabetic character followed by `:`), or begins with `\\` (UNC),
- contains a `..` path component (split on both `/` and `\`, and compare whole
  components, so a file legitimately named `..foo.glsl` is not refused),
- contains a NUL byte.

Return a new distinct error, for example `error.UnsafeIncludePath`, rather than
`error.FileNotFound`, so the diagnostic can say why. Add it to the function's
error set and make sure the message names the offending include text.

This check is pure string handling with no filesystem access, so it is safe on
the freestanding target. Apply it to both `#include "..."` and `#include <...>`.

**Verify**:
- `mise exec -- zig build test` -> exit 0
- `mise exec -- zig build strict-gate` -> exit 0, PASS 2108, XFAIL 13

If the strict gate drops, a real fixture uses `..` in an include. That is a STOP
condition, see below.

### Step 2: Verify the resolved path stays under its root

Inside the existing `if (builtin.os.tag != .freestanding)` block, after a
candidate `full_path` is built and **before** it is read, resolve it to a real
path and confirm containment:

1. Resolve the candidate and its intended root to absolute, normalized form.
   `std.fs.realpath` (or the `compat.zig` equivalent if one exists, check first
   with `grep -n "realpath\|resolve" src/compat.zig`) resolves symlinks, which
   is what closes the symlink-escape case that pure string normalization misses.
2. Resolve the root the same way: `dir_part` for the source-relative branch, the
   `inc_path` entry for the `-I` branch.
3. Require the resolved candidate to be a path-component-wise prefix of the
   resolved root. Compare components, not raw bytes, so `/srv/shaders-evil` is
   not accepted as being under `/srv/shaders`.
4. On failure in the source-relative branch, return `error.UnsafeIncludePath`.
   In the `-I` loop, `continue` to the next root (a miss on one root is normal),
   and if no root matches, the existing not-found path applies.

Step 1 already blocks the common cases cheaply; this step is what catches
symlink escapes and anything the spelling check cannot see.

**Verify**:
- `mise exec -- zig build test` -> exit 0
- `mise exec -- zig build strict-gate` -> exit 0, PASS 2108, XFAIL 13
- `mise exec -- zig build wasm` -> exit 0 (freestanding still compiles, no
  `std.fs` leaked outside the guard)

### Step 3: DESCOPED, DO NOT IMPLEMENT

> Removed from this plan on 2026-08-04. See the "SCOPE SPLIT" note in the Scope
> section for the two reproduced regressions that caused it. Skip straight from
> step 2 to step 4. Leave cycle detection and `#pragma once` handling exactly as
> they are on `main`. The text below is retained only so the deferred work has a
> written starting point; it is NOT an instruction.

### Step 3 (DEFERRED, reference only): Key cycle detection on the resolved path and restore `#pragma once` semantics

Change the include bookkeeping so that:

1. `included_files` becomes an **active include stack**, not a permanent set:
   push the resolved absolute path before recursing into the included file, pop
   it after. A hit while the path is on the stack is a genuine cycle: return a
   clear error (or the existing early return, matching how the current code
   reports cycles, but keyed correctly).
2. `pragma_once_files` keeps its current permanent-set semantics, but is also
   keyed on the **resolved absolute path** rather than the token text. This is
   the set that legitimately suppresses a second inclusion.
3. A file included twice **without** `#pragma once` and without being on the
   active stack is now included twice, which is correct C and GLSL behavior.

The resolved path is produced in step 2; thread it out of the resolver so the
bookkeeping can use it. That may mean the resolver returns a small struct
(`{ source: [:0]const u8, resolved_path: []const u8 }`) instead of just the
source bytes. Own the resolved-path string with the same allocator and lifetime
discipline the existing `path_copy` uses at `src/preprocessor.zig:252-254`.

On the freestanding path where there is no filesystem, keep using the token text
as the key. Note that in a comment.

**Verify**:
- `mise exec -- zig build test` -> exit 0
- `mise exec -- zig build strict-gate` -> exit 0, PASS 2108, XFAIL 13
- `mise exec -- zig build conformance` -> exit 0

**This is the step most likely to move fixture behavior.** A fixture that
currently relies on the accidental include-once may now include a header twice
and hit a duplicate-definition error. If the strict gate drops here, see STOP
conditions.

### Step 4: Add include-resolution tests

Create `tests/include_tests.zig` with a temporary directory tree built at test
time (use `std.testing.tmpDir`, and follow the structure and allocator style of
`tests/optimizer_tests.zig`).

Cases:

- **Traversal refused**: a shader with `#include "../../../etc/passwd"` returns
  `error.UnsafeIncludePath` and does not read the file.
- **Absolute refused**: `#include "/etc/passwd"` returns `error.UnsafeIncludePath`.
- **Windows drive refused**: `#include "C:/Windows/win.ini"` returns
  `error.UnsafeIncludePath`.
- **Symlink escape refused**: create a symlink inside the include root pointing
  outside it, include through the symlink, expect refusal. Skip this case on
  platforms where the test cannot create symlinks, and say so in the skip
  message.
- **Legitimate sibling include still works**: `#include "helper.glsl"` next to
  the source resolves and compiles.
- **Legitimate `-I` include still works**: a header found through a configured
  include root resolves and compiles.
- **Double inclusion without `#pragma once` includes twice**: a header defining
  a macro that is `#undef`ed between the two includes is expanded both times.
- **`#pragma once` still suppresses the second include**.
- **Genuine cycle is detected**: a.glsl includes b.glsl includes a.glsl,
  terminates with an error rather than recursing forever.

Wire the file into the test build the same way the other `tests/*.zig` files are
wired in `build.zig`.

**Verify**: `mise exec -- zig build test` -> exit 0, 8 or 9 new tests pass.

### Step 5: Run the full gate

**Verify**: all of the following exit 0:
- `mise exec -- zig fmt --check src`
- `mise exec -- zig build test`
- `mise exec -- zig build strict-gate` (PASS 2108, XFAIL 13)
- `mise exec -- zig build conformance`
- `mise exec -- zig build wasm`
- `mise exec -- zig build cli`

## Test plan

Covered in step 4. The structural pattern to follow is
`tests/optimizer_tests.zig`. The two cases that matter most:

- The traversal refusal is the security regression test.
- The "double inclusion without `#pragma once`" case is the regression test for
  the silent-wrong half, and it is the one most likely to be missing from the
  existing suite entirely.

**Verification**: `mise exec -- zig build test` -> all pass, 8 or 9 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `mise exec -- zig fmt --check src` exits 0
- [ ] `mise exec -- zig build test` exits 0, `tests/include_tests.zig` exists
      and its tests pass
- [ ] `mise exec -- zig build strict-gate` exits 0, PASS 2108, XFAIL 13
      (identical to before this plan)
- [ ] `mise exec -- zig build conformance` exits 0
- [ ] `mise exec -- zig build wasm` exits 0
- [ ] `mise exec -- zig build cli` exits 0
- [ ] `grep -n "UnsafeIncludePath" src/preprocessor.zig` returns matches in both
      the spelling check and the containment check
- [ ] `grep -n "included_files.contains" src/preprocessor.zig` shows the check
      keyed on a resolved path, not the raw token
- [ ] No files outside the in-scope list are modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts at `src/preprocessor.zig:430-463` or `:230-236` do not match the
  live code.
- **The strict gate drops below PASS 2108 at step 1 or 2.** A real fixture is
  using a traversal or absolute include. Do not relax the check to accommodate
  it. Report the fixture and the include spelling; the maintainer decides
  whether the fixture is wrong or the policy needs a documented exception.
- **The strict gate drops at step 3.** This is the expected-risk step: a fixture
  probably relied on the accidental include-once and now gets a duplicate
  definition. Report which fixtures and what error. Do NOT restore the old
  keying to make the gate green, and do NOT edit the fixtures. The correct
  resolution (add `#pragma once` to the header, or accept the fixture change) is
  a maintainer decision.
- `std.fs.realpath` is unavailable or behaves differently on the pinned Zig
  0.15.2 versus 0.16, and `src/compat.zig` has no shim. A version shim belongs
  in `compat.zig`, which is out of scope here. Report and stop.
- `mise exec -- zig build wasm` fails after step 2. You have leaked a filesystem
  API into the freestanding build; move the code inside the
  `builtin.os.tag != .freestanding` guard.
- Threading the resolved path out of the resolver (step 3) requires changing the
  preprocessor's public API in a way that touches `src/root.zig` or `src/cli.zig`.

## Maintenance notes

- **The two checks are complementary and both are needed.** The spelling check
  (step 1) is cheap and catches the common cases before any I/O. The realpath
  containment check (step 2) is what catches symlink escapes. Removing either
  one reopens a hole; a reviewer should verify both survive future refactors.
- The freestanding/wasm path deliberately keeps token-text keying because there
  is no filesystem to resolve against. If the wasm playground ever gains a
  virtual filesystem, that path needs its own containment policy.
- If a legitimate use case for `..` in includes appears (a shared header one
  directory up), the right answer is an additional `-I` root, not relaxing the
  spelling check. Document that if it comes up.
- Deliberately deferred: rate-limiting or depth-limiting include recursion. The
  active-stack cycle detection from step 3 bounds infinite recursion, but a
  deeply nested legitimate include chain still consumes stack. Worth a maximum
  include depth later; not required for this plan.
- A reviewer should scrutinize: that `included_files` is genuinely popped on
  every exit path from the recursive include (including error paths, so use
  `defer`), otherwise a legitimate second include of the same file is
  incorrectly reported as a cycle.
