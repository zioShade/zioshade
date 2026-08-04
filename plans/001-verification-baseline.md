# Plan 001: Make the conformance gate fail loudly and enforce it in CI

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report, do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 0816eba..HEAD -- tests/runner.zig .github/workflows/ci.yml justfile`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `0816eba`, 2026-08-03

## Why this matters

The 2108-fixture strict gate is this project's headline verification artifact,
cited in the README badge and in CONTRIBUTING as a merge invariant. Today it
structurally cannot distinguish "2108 fixtures passed" from "the fixture
directory was renamed and nothing ran" or "spirv-val vanished and everything
skipped": every infrastructure failure degrades to `.skip`, and the process
exits 0 unless something explicitly failed. On top of that, `zig build
strict-gate` runs in no CI job at all, so the invariant it protects is enforced
only when the maintainer remembers to run it locally.

This plan is the prerequisite for every other plan in this directory. Plans 002
through 005 change parsing, memory, and optimizer behavior, and they are only
safe to land if a green gate actually means something. Fix the gate first.

## Current state

Files in scope and their role:

- `tests/runner.zig` (721 lines) - the conformance/strict-gate runner. Walks
  fixture directories, compiles each shader, validates the SPIR-V with Khronos
  `spirv-val`, and tallies pass/fail/skip.
- `.github/workflows/ci.yml` - 7 jobs: `fmt`, `build-test`, `conformance`,
  `spv-validity`, `cts-ingestion`, `fuzz-smoke`, `c-abi`.
- `justfile` - the local command surface. Line 377 defines the `ci` recipe.

**Every infrastructure failure degrades to a skip.** `tests/runner.zig:188-206`:

```zig
    const tmp_path: []const u8 = if (save_spv) |sp| sp else blk: {
        var buf: [compat.max_path_bytes]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, ".zig-cache/conformance-{}.spv", .{compat.randomInt(u64)}) catch return .skip;
    };
    const tmp_file = compat.dirCreateFile(io, dir, tmp_path, .{}) catch return .skip;
    defer {
        compat.fileClose(io, tmp_file);
        // Keep the file if validation failed, for debugging
    }
    compat.fileWriteAll(io, tmp_file, std.mem.sliceAsBytes(words)) catch return .skip;

    // Run spirv-val. Degrade to .skip (not .fail) when it cannot be spawned at
    // all - e.g. VULKAN_SDK unset and no spirv-val on PATH - so a missing tool
    // doesn't masquerade as a conformance failure.
    const spirv_val = compat.resolveSpirvVal(alloc) catch return .skip;
    defer alloc.free(spirv_val);
    const val_result = compat.processRun(io, alloc, &.{ spirv_val, tmp_path }) catch return .skip;
```

Note the distinction the existing comment already draws: a missing `spirv-val`
is a *legitimate* skip. A failed `bufPrint`, `dirCreateFile`, or `fileWriteAll`
is **not** - that is local I/O breaking, and it currently produces the same
silent `.skip`.

**Any error from a shader becomes a skip**, `tests/runner.zig:408` and `:678`:
`testShader(...) catch .skip` swallows every error including `error.OutOfMemory`.

**A missing fixture directory is swallowed entirely**, `tests/runner.zig:683`
and `:688`: `runDir(...) catch {}`.

**Exit code ignores skips and an empty run**, `tests/runner.zig:714-718`:

```zig
    log("TOTAL:          {d}\n", .{stats.total()});

    if (stats.fail > 0 or stats.compile_error > 0) {
        std.process.exit(1);
    }
```

A run with TOTAL 0 exits 0. A run where all 2108 fixtures skipped exits 0.

**`strict-gate` runs in no CI job.** Verified: `grep -c "strict-gate"
.github/workflows/ci.yml` returns `0`, while `justfile:377` has
`ci: test test-hlsl validate-dxc validate-metal strict-gate oracle-diff spv-validity cts-ingestion`.

**The WGSL oracle is absent from the unit-test job.** `tests/wgsl_tests.zig:250-253`
defines `nagaValidateOrSkip`, which probes `naga --version` and does
`catch return error.SkipZigTest`. There are 224 `try nagaValidateOrSkip(...)`
call sites in that file. `naga` is installed in `ci.yml` only at lines 173 and
207 (the `spv-validity` and `cts-ingestion` jobs, which run shell sweeps, not
`zig build test`). The `build-test` job, the only job that runs the Zig test
suite, installs `glslang-tools spirv-tools` and not naga, so all 224 assertions
skip in CI.

Repo conventions to match:

- Commit messages are conventional-commit style with a trailing PR number. From
  `git log`: `fix(glsl,hlsl): mangle function-scope ids that shadow a global (#sid, v2) (#540)`,
  `ci(conformance): skip setup-zig cache on Windows (fix xs3) (#529)`.
- **No AI attribution in commits**: do not add `Co-Authored-By` trailers.
- **Do not use em dashes** in code comments, commit messages, or docs in this
  repo. Use commas, parentheses, or hyphens.
- Zig is pinned to 0.15.2 via `.mise.toml`. Prefix builds with `mise exec --`
  when the system Zig is newer.
- CI installs naga with the exact command `cargo install naga-cli --version 30.0.0`
  (`ci.yml:173`). Reuse that pinned version verbatim; do not bump it.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format check | `mise exec -- zig fmt --check src` | exit 0 |
| Unit tests | `mise exec -- zig build test` | exit 0, all tests pass |
| Strict gate | `mise exec -- zig build strict-gate` | exit 0, reports PASS 2108 / XFAIL 13 |
| Conformance | `mise exec -- zig build conformance` | exit 0 |
| Workflow lint | `grep -n "strict-gate" .github/workflows/ci.yml` | at least one match after step 3 |

Run `mise trust && mise install` once first if `mise exec` fails.

## Scope

**In scope** (the only files you should modify):
- `tests/runner.zig`
- `.github/workflows/ci.yml`
- `justfile`

**Out of scope** (do NOT touch, even though they look related):
- `tests/wgsl_tests.zig` - the `nagaValidateOrSkip` helper stays as is. This
  plan installs the oracle in CI so the existing assertions run; changing the
  helper's skip semantics is deliberately deferred (see Maintenance notes).
- Any fixture under `tests/conformance/`, `tests/cts/`, or `tests/fixtures/` -
  changing fixture counts while changing the counter logic makes the result
  uninterpretable.
- `tests/cts/baseline.txt` - the crash baseline is a separate mechanism.
- Any file under `src/` - this plan changes no compiler behavior.

## Git workflow

- Branch: `advisor/001-verification-baseline`
- One commit per step, conventional-commit style. Example for step 1:
  `test(runner): fail on infra errors instead of degrading to skip`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add an `.infra_error` result that always fails

In `tests/runner.zig`, find the result enum that carries `.skip`, `.fail`,
`.pass`, and `.compile_error` (it is the return type of `testShader`). Add a
new variant `infra_error`.

Convert these sites from `catch return .skip` to `catch return .infra_error`
(these are local I/O and formatting failures, not missing-tool conditions):

- `tests/runner.zig:190` - `std.fmt.bufPrint(...) catch return .skip`
- `tests/runner.zig:192` - `compat.dirCreateFile(...) catch return .skip`
- `tests/runner.zig:197` - `compat.fileWriteAll(...) catch return .skip`

**Leave these two as `.skip`** - a missing tool is a legitimate skip and the
existing comment says so:

- `tests/runner.zig:202` - `compat.resolveSpirvVal(...) catch return .skip`
- `tests/runner.zig:204` - `compat.processRun(...) catch return .skip`

Add an `infra_error` counter to the stats struct, print it in the summary
block near `tests/runner.zig:714`, and include it in the exit condition:

```zig
    if (stats.fail > 0 or stats.compile_error > 0 or stats.infra_error > 0) {
        std.process.exit(1);
    }
```

**Verify**: `mise exec -- zig build strict-gate` -> exit 0, summary now prints an
`INFRA_ERROR: 0` line alongside the existing counters.

### Step 2: Add a minimum-PASS floor and fail on an empty run

Still in `tests/runner.zig`:

1. Change `testShader(...) catch .skip` at lines 408 and 678 to route errors to
   `.infra_error` rather than `.skip`, so an OOM or unexpected error fails.
2. Change `runDir(...) catch {}` at lines 683 and 688 to report the failure and
   set a flag that forces a non-zero exit. A renamed or missing fixture
   directory must not be silent.
3. Add a `--min-pass=N` command-line flag. When supplied and `stats.pass < N`,
   print a clear message (`FAIL: expected at least N passing fixtures, got M`)
   and exit 1. When not supplied, behave as before.
4. Independently of the flag, exit 1 when `stats.total() == 0`.

**Verify**:
- `mise exec -- zig build strict-gate` -> exit 0 (unchanged behavior with no flag).
- Run the runner binary directly with `--min-pass=999999` and confirm it exits 1
  with the expected message. Find the binary path from `zig build --help` output
  for the `strict-gate` step, or invoke the step with the flag appended after
  `--`. If you cannot pass the flag through the build step in one try, add a
  short-lived `just` recipe or invoke the compiled runner from `zig-out/bin/`;
  do not spend more than two attempts on plumbing.

### Step 3: Add `strict-gate` to CI and install the naga oracle in `build-test`

In `.github/workflows/ci.yml`:

1. Add a `zig build strict-gate` step to the existing `conformance` job (that
   job already installs `spirv-val`, verified at `ci.yml:135`, so it has the
   inputs). Pass the minimum-pass floor: use the count the gate currently
   reports, which is **2108**. Write it as `--min-pass=2108` if step 2's flag
   plumbs through the build step; if it does not, add the floor as a separate
   `zig build strict-gate` invocation of the runner binary with the flag.
2. In the `build-test` job (starts at `ci.yml:34`), add a naga install step
   before the test step, on the Linux leg only:

   ```yaml
         - name: Install naga (WGSL oracle)
           if: runner.os == 'Linux'
           run: cargo install naga-cli --version 30.0.0
   ```

   Use that exact pinned version, matching `ci.yml:173`.

**Verify**:
- `grep -c "strict-gate" .github/workflows/ci.yml` -> at least 1.
- `grep -c "naga-cli --version 30.0.0" .github/workflows/ci.yml` -> 3.
- The YAML parses: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` -> exit 0.

### Step 4: Make `just ci` and the workflow describe each other honestly

`justfile:2` currently claims "Run `just` or `just ci` to execute the full CI
pipeline locally", but `just ci` (line 377) and the workflow gate different
things in both directions: `just ci` includes `validate-dxc`, `validate-metal`,
`strict-gate`, and `oracle-diff` which CI does not run, and omits `conformance`,
`c-abi`, and `fuzz` which CI does run.

Split the recipe:

- `ci` becomes the exact local mirror of the GitHub workflow (the jobs that run
  on every PR).
- `ci-full` keeps the oracle-dependent extras (`validate-dxc`, `validate-metal`,
  `oracle-diff`, and the render proofs) that need local hardware or toolchains.

Update the comment at `justfile:2` to say which recipe mirrors CI and which one
needs local oracles.

**Verify**: `just --list` -> both `ci` and `ci-full` appear. `just --dry-run ci`
-> exit 0 and the printed recipe list matches the workflow's job set.

### Step 5: Run the full local gate

**Verify**: all of the following exit 0:
- `mise exec -- zig fmt --check src`
- `mise exec -- zig build test`
- `mise exec -- zig build strict-gate`
- `mise exec -- zig build conformance`

## Test plan

This plan changes test infrastructure, so the tests are the runner's own
behavior. Add to `tests/runner.zig` (or a new `tests/runner_selftest.zig` if
the runner has no test blocks, following the structure of
`tests/optimizer_tests.zig`):

- A test asserting that a stats struct with `pass = 0, total = 0` produces a
  non-zero exit decision.
- A test asserting that `infra_error > 0` produces a non-zero exit decision
  even when `fail == 0`.
- A test asserting that `pass < min_pass` produces a non-zero exit decision.

Factor the exit decision into a small pure function
(`fn shouldFail(stats: Stats, min_pass: ?usize) bool`) so these are unit
tests rather than process-spawning tests. Model the test-block style on
`tests/optimizer_tests.zig`.

**Verification**: `mise exec -- zig build test` -> all pass, including 3 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `mise exec -- zig fmt --check src` exits 0
- [ ] `mise exec -- zig build test` exits 0, and 3 new runner self-tests pass
- [ ] `mise exec -- zig build strict-gate` exits 0 and reports PASS 2108, XFAIL 13
- [ ] `mise exec -- zig build conformance` exits 0
- [ ] `grep -c "strict-gate" .github/workflows/ci.yml` returns at least 1
- [ ] `grep -c "naga-cli --version 30.0.0" .github/workflows/ci.yml` returns 3
- [ ] `just --list` shows both `ci` and `ci-full`
- [ ] `grep -n "catch return .skip" tests/runner.zig` shows only the two
      tool-resolution sites (`resolveSpirvVal`, `processRun`)
- [ ] No files outside the in-scope list are modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at `tests/runner.zig:188-206` or `:714-718` does not match the
  excerpts above.
- `mise exec -- zig build strict-gate` does not report PASS 2108 before you
  change anything. Record the actual number and stop: the floor in step 3 must
  be the real current count, and a different number means the baseline moved.
- Turning on the naga oracle in `build-test` cannot be verified locally and you
  have no way to tell whether the 224 assertions pass. Land steps 1, 2, 4 and
  the `strict-gate` half of step 3, and report the naga step as untested.
- Adding `--min-pass` requires changing how `build.zig` defines the
  `strict-gate` step in a way that touches more than the step's `addArgs`.
- Step 2's change to `runDir(...) catch {}` reveals that a fixture directory is
  already missing (the gate was silently skipping a whole suite). Report the
  directory name and stop, that is a finding in its own right.

## Maintenance notes

- The `--min-pass` floor must be bumped whenever fixtures are added. That is
  intended friction: it makes a fixture-count change visible in the diff. The
  natural follow-up is to commit per-suite expected counts next to
  `KNOWN_UNSUPPORTED` in `tests/runner.zig` so the floor is per-suite rather
  than a single global number.
- Deliberately deferred: making `nagaValidateOrSkip` hard-fail under an opt-in
  `ZIOSHADE_REQUIRE_ORACLES=1` env var. Installing naga in CI captures most of
  the value; the env-var gate is a second change and should land only after the
  224 assertions are confirmed green in CI for at least one cycle.
- Also deferred: CI legs for the HLSL (DXC) and MSL (Metal) validity sweeps,
  which today run only on the maintainer's machine. Those are the two backends
  wintty actually links, so they are the highest-value CI additions after this
  plan, but they need new Windows and macOS jobs rather than edits to existing
  ones.
- A reviewer should scrutinize: that the two tool-resolution sites still degrade
  to `.skip` (so a contributor without the Vulkan SDK is not blocked), and that
  the `--min-pass` value in CI matches the number the gate actually reports.
