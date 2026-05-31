# Analyzer Fail-Loud — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Design spec:** [`docs/specs/2026-05-31-analyzer-fail-loud-design.md`](../specs/2026-05-31-analyzer-fail-loud-design.md) (approved, merged in PR #35). Read it first — this plan implements it.

**Goal:** Make the plain `compileToSPIRV` / `compileToSPIRVNoOpt` APIs **fail loud** (`error.SemanticFailed`) on genuinely-broken shaders, by first eliminating every analyzer false-positive that forces `tolerate_errors=true` today, verified against an empirical corpus + `glslang -V` oracle bar.

**Architecture:** Two phases. **Phase A** builds a *repeatable enumeration harness* (Task 0) that lists every fixture the strict analyzer over-rejects, classifies each against `glslang -V`, then models the false-positives one category at a time (Task 1 template) and honest-errors the genuinely-unrepresentable ones (Task F1). **Phase B** flips the plain APIs to collect-all-then-fail by hoisting the proven error-kind check from `compileToSPIRVWithDiagnostics` (Task F2) and reclassifies the 7 known conformance fails as expected honest rejections (Task F3). The category list in the spec is a *hypothesis*; Task 0 produces the real worklist.

**Tech Stack:** Zig 0.15.2 (pinned via `mise`; build with `mise exec -- zig`). Test harness `zig build test`. Oracles: `spirv-val` (`C:\VulkanSDK\1.4.341.1\Bin\spirv-val.exe`) and `glslangValidator -V` (`C:\VulkanSDK\1.4.341.1\Bin\glslangValidator.exe`). Local gate `just ci` + `just test-conformance`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `src/root.zig` | public compile APIs | Add `compileToSPIRVStrict` (Task 0); flip `compileToSPIRV`/`compileToSPIRVNoOpt` to collect-all-then-fail (Task F2) |
| `tests/runner.zig` | conformance + enumeration runner | Add `--strict-enumerate` mode (Task 0); add XFAIL known-unsupported list (Task F3) |
| `build.zig` | build steps | Add `enumerate-fp` step (Task 0) |
| `src/semantic.zig` | analyzer | Per-category modeling of over-rejected valid GLSL (Task 1 instances); honest-error for unrepresentable (Task F1) |
| `tests/conformance/stress/*.{frag,vert,comp}` | regression fixtures | One valid-GLSL fixture per modeled construct (Task 1 instances) |
| `tests/analyzer_strict_tests.zig` | new strict-mode unit tests | Per-construct RED→GREEN assertions + the post-flip contract (Tasks 1, F2) |
| `justfile` | local gate | Add `enumerate-fp` recipe (Task 0) |

Wire `tests/analyzer_strict_tests.zig` into the default `test` step in `build.zig` the same way the other `tests/*.zig` modules are wired (mirror the `test-diagnostic` / `test-reflection` pattern, then `test_step.dependOn(&run_strict_tests.step)`).

---

## Task 0 — Strict-mode enumeration harness (load-bearing)

**Goal:** a reproducible tool that lists every fixture the strict analyzer rejects, with its error context, so the false-positive worklist is ground truth, not a guess.

**Files:**
- Modify: `src/root.zig` (add `compileToSPIRVStrict`)
- Modify: `tests/runner.zig` (add `--strict-enumerate` mode)
- Modify: `build.zig` (add `enumerate-fp` step)
- Modify: `justfile` (add recipe)

- [ ] **Step 1: Add `compileToSPIRVStrict` to `src/root.zig`.**

  This is `compileToSPIRVNoOpt` (at `src/root.zig:486`) with one change — `analyzeWithOptions` is called with `.tolerate_errors = false`. Place it next to `compileToSPIRVNoOpt`:

  ```zig
  /// Strict variant: semantic errors are NOT tolerated — analysis returns
  /// error.SemanticFailed on the first recorded error. Used ONLY by the
  /// strict-enumeration harness (tests/runner.zig --strict-enumerate) to surface
  /// analyzer false-positives. NOT a public compile path.
  pub fn compileToSPIRVStrict(
      alloc: std.mem.Allocator,
      source: [:0]const u8,
      options: CompileOptions,
  ) Error![]const u32 {
      last_compile_detail = null;
      const tokens = lexer.tokenize(alloc, source) catch {
          last_compile_detail = .lex_failed;
          semantic.last_error_line = lexer.last_error_line;
          semantic.last_error_column = lexer.last_error_column;
          return error.LexFailed;
      };
      defer alloc.free(tokens);

      var pp = preprocessor.Preprocessor.init(alloc);
      defer pp.deinit();
      const pp_tokens = pp.process(source, tokens) catch tokens;
      defer if (pp_tokens.ptr != tokens.ptr) alloc.free(pp_tokens);

      var root_node = parser.parse(alloc, source, pp_tokens) catch {
          last_compile_detail = .parse_failed;
          return error.ParseFailed;
      };
      defer parser.freeTree(alloc, &root_node);

      var module = semantic.analyzeWithOptions(alloc, &root_node, .{ .tolerate_errors = false, .stage = options.stage }) catch {
          last_compile_detail = .semantic_failed;
          return error.SemanticFailed;
      };
      module.deinit();
      // Enumeration only cares whether analysis SUCCEEDS; it does not need codegen.
      return &[_]u32{};
  }
  ```

- [ ] **Step 2: Run to verify it compiles.**

  Run: `mise exec -- zig build` — Expected: builds clean (new public fn, no callers yet).

- [ ] **Step 3: Add `--strict-enumerate` mode to `tests/runner.zig`.**

  In `mainImpl` (`tests/runner.zig:232`), parse a `--strict-enumerate` flag alongside the existing arg loop (around `:251`). When set, run a separate pass: for every fixture in `all_suites` (reuse the existing `runDir`/walk filters), compile with BOTH `glslpp.compileToSPIRV` (tolerate, current behavior) and `glslpp.compileToSPIRVStrict`. A fixture is a **false-positive candidate** when the tolerate compile *succeeds* but the strict compile *fails with `error.SemanticFailed`*. For each candidate, print `path`, `glslpp.lastErrorCtx()`, and `glslpp.lastErrorInner()` (the runner already surfaces these at `tests/runner.zig:139-141`). Tally candidates and print a per-`ctx` histogram at the end.

  Add a `strict_fp: u32 = 0` field to `Stats`, a new `enumerateShader` helper mirroring `testShader` (`:72`) but doing the dual-compile compare, and a `--strict-enumerate` branch in `mainImpl` that walks the suites calling `enumerateShader`. Do NOT run `spirv-val` in this mode (we only care about analyzer accept/reject). Exit 0 always in `--strict-enumerate` mode (it's a report); the gating `--strict-gate` variant that exits non-zero on any candidate is added in **Task F2 Step 5**. Note: `compileToSPIRVStrict` returns a static empty slice, so a `defer alloc.free(spirv)` copied from `testShader` (`:144`) is a **safe no-op** on the strict result — do not "fix" it.

- [ ] **Step 4: Add the `enumerate-fp` build step in `build.zig`.**

  Mirror the `conformance` step block (`build.zig:159-178`): the runner module/exe already exist (`runner_exe`); add a second `b.addRunArtifact(runner_exe)`, append the `--strict-enumerate` arg, and wire it to `const enumerate_step = b.step("enumerate-fp", "List analyzer false-positive candidates (strict vs tolerate)");`.

- [ ] **Step 5: Add the `justfile` recipe.**

  ```just
  # list analyzer false-positive candidates (strict vs tolerate compile)
  enumerate-fp:
      {{zig}} build enumerate-fp --summary all
  ```

- [ ] **Step 6: Run the harness and capture the worklist.**

  Run: `just enumerate-fp 2>&1 | tee /tmp/fp_enumerate.log`
  Expected: a list of false-positive candidates + a per-`ctx` histogram. **This output is the input to Tasks 1..N.** Record it (paste the histogram into the PR / a tracking issue).

- [ ] **Step 7: Classify each candidate against the oracle.**

  For each distinct `ctx`/construct, run `glslangValidator -V <fixture>`:
  - glslang **accepts** + glslpp *could* emit correct output → **false-positive** → Task 1 instance.
  - glslang **accepts** + glslpp cannot represent (fp64/int64/etc.) → **Task F1** honest-error.
  - glslang **rejects** → already-correct, leave as-is (record it so it's not re-investigated).

  Produce a classified table: `construct | ctx | count | glslang verdict | bucket`. Commit it as a comment block at the top of `tests/analyzer_strict_tests.zig`.

- [ ] **Step 8: Add a harness self-test (spec-mandated).**

  The enumerator produces the *entire* worklist, so an untested one that silently under-reports would hide false-positives — exactly the silent-wrong failure this milestone exists to kill. Add a unit test to `tests/analyzer_strict_tests.zig` asserting the enumerator's detection arm (`compileToSPIRVStrict` rejects a recorded error). Use an **undeclared identifier** as the seed — it is a permanent, flip-independent error (glslang rejects it too), so the test does not break when Task 1 models real false-positives or when Task F2 flips the plain API:
  ```zig
  test "harness self-test: compileToSPIRVStrict rejects a recorded error" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(location=0) out vec4 o;
          \\void main() { o = vec4(undeclared_xyz, 0.0, 0.0, 1.0); }
          ;
      // The strict arm is the enumerator's detection signal; it must fire.
      try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment }));
  }
  ```

- [ ] **Step 9: Commit.**

  ```bash
  git add src/root.zig tests/runner.zig build.zig justfile tests/analyzer_strict_tests.zig
  git commit -m "feat(analyzer): strict-mode false-positive enumeration harness + self-test"
  ```

---

## Task 1 — Model one false-positive category (REPEATABLE TEMPLATE)

> **This task is a template instantiated once per false-positive bucket from Task 0's classified table, ordered by histogram frequency (highest first).** The RED/verify/commit steps below are fully concrete and identical for every instance; only the GREEN step's analyzer edit varies by construct (written against the specific `src/semantic.zig` path the RED fixture exercises — that read-and-edit IS the per-instance work). If Task 0 surfaces many buckets, re-run `writing-plans` to expand this into one numbered task per bucket; do not hand-wave them into a single step.

**Files (per instance):**
- Create: `tests/conformance/stress/<construct>.{frag|vert|comp}` (a minimal valid-GLSL shader using the construct)
- Modify: `src/semantic.zig` (model the construct)
- Modify: `tests/analyzer_strict_tests.zig` (RED→GREEN assertion)

- [ ] **Step 1: Confirm the oracle accepts it (guardrail — do this before writing any code).**

  Run: `& "C:\VulkanSDK\1.4.341.1\Bin\glslangValidator.exe" -V tests/conformance/stress/<construct>.frag`
  Expected: exit 0 (glslang accepts). **If glslang rejects, STOP — this is not a false-positive; glslpp rejecting it is correct.**

- [ ] **Step 2: Write the failing (RED) strict-mode test in `tests/analyzer_strict_tests.zig`.**

  ```zig
  test "strict: <construct> is accepted (no false-positive)" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\// ... minimal valid GLSL using <construct>, identical to the fixture ...
          ;
      // Strict analysis must NOT reject valid GLSL.
      const spirv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      // Real assertion: the construct lowered to a real instruction, not OpUndef.
      try std.testing.expect(spirv.len > 5);
  }
  ```

- [ ] **Step 3: Run it — confirm it FAILS today.**

  Run: `mise exec -- zig build test 2>&1 | grep -A3 "<construct>"`
  Expected: FAIL (semantic over-rejects, or codegen emits `OpUndef`-backed output). Record the exact `lastErrorCtx`.

- [ ] **Step 4: Model the construct in `src/semantic.zig` (GREEN).**

  Read the `src/semantic.zig` path the error points at (the `ctx` from Task 0 names the branch). Implement real handling — register the builtin / type / lvalue form / loop-update form so analysis accepts it AND codegen emits correct SPIR-V. **Per the spec's classification rule, the GREEN is only valid if codegen produces oracle-clean output — never satisfy the test by suppressing the error while emitting `OpUndef`.**

- [ ] **Step 5: Verify GREEN with BOTH oracles (never string-match alone).**

  ```bash
  mise exec -- zig build test 2>&1 | grep "<construct>"        # unit test passes
  mise exec -- zig build cli
  zig-out/bin/glslpp.exe compile tests/conformance/stress/<construct>.frag --stage fragment -o /tmp/c.spv
  & "C:\VulkanSDK\1.4.341.1\Bin\spirv-val.exe" /tmp/c.spv      # spirv-val PASS
  ```
  Expected: unit test passes AND spirv-val passes. Also re-run `just enumerate-fp` and confirm this `ctx` count dropped (true blast-radius shrink, per the spec's dedup heuristic — cascade phantoms vanish when the root cause is modeled).

- [ ] **Step 6: Full regression + commit.**

  ```bash
  mise exec -- zig build test --summary all   # no regression vs baseline
  git add tests/conformance/stress/<construct>.frag src/semantic.zig tests/analyzer_strict_tests.zig
  git commit -m "fix(analyzer): model <construct> — no longer a false-positive"
  ```

Repeat Task 1 for each bucket until `just enumerate-fp` reports **zero** false-positive candidates (every remaining strict-reject is either an F1 honest-error case or a glslang-confirmed true rejection).

---

## Task F1 — Honest-error pass for genuinely-unrepresentable constructs

**Goal:** valid GLSL glslpp cannot represent (fp64/int64, etc.) must produce a clean, *named* `error.Unsupported*` with line/col — never silently-invalid SPIR-V.

**Files:** `src/semantic.zig`, `tests/analyzer_strict_tests.zig`

- [ ] **Step 1: For each F1-bucket construct from Task 0, write a RED test asserting an honest error.**

  ```zig
  test "strict: fp64 yields an honest unsupported-type error (not invalid SPIR-V)" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(location=0) out vec4 o;
          \\void main() { double d = 1.0lf; o = vec4(float(d)); }
          ;
      try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment }));
      // And the error names the construct + location (no silent OpUndef path):
      try std.testing.expect(glslpp.lastErrorCtx() != null);
  }
  ```

- [ ] **Step 2: Run — confirm it fails today** (currently emits invalid SPIR-V at exit 0 instead of erroring). Run: `mise exec -- zig build test 2>&1 | grep fp64`.

- [ ] **Step 3: Add the honest-error guard in `src/semantic.zig`** at the point the unrepresentable type/op is first seen — set `last_error_ctx`/`last_error_inner` + line/col and `return error.SemanticFailed` (mirror the existing `literalWord` over-range precedent). Never truncate, never `OpUndef`.

- [ ] **Step 4: Verify + commit.**

  ```bash
  mise exec -- zig build test 2>&1 | grep fp64   # passes (honest error)
  git add src/semantic.zig tests/analyzer_strict_tests.zig
  git commit -m "fix(analyzer): honest unsupported-type error for fp64/int64 (no silent-invalid SPIR-V)"
  ```

---

## Task F2 — Flip the plain APIs to collect-all-then-fail

**Precondition:** `just enumerate-fp` reports **zero** false-positive candidates AND the Done-bar oracle sweep (below) is clean. Do NOT start F2 before that.

**Files:** `src/root.zig`, `tests/analyzer_strict_tests.zig`

- [ ] **Step 1: Write the contract test (RED).**

  ```zig
  test "flip: plain compileToSPIRV fails loud on a genuinely-broken shader" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(location=0) out vec4 o;
          \\void main() { o = vec4(undeclared_identifier_xyz, 0, 0, 1); }
          ;
      try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment }));
  }

  test "flip: plain compileToSPIRV still accepts the full valid corpus" {
      // Sanity: a known-good shader still compiles (no new false-positive from the flip).
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(location=0) out vec4 o;
          \\void main() { o = vec4(1.0); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      try std.testing.expect(spirv.len > 5);
  }
  ```

- [ ] **Step 2: Run — confirm the first test FAILS today** (plain API silently returns a partial module instead of erroring). Run: `mise exec -- zig build test 2>&1 | grep flip`.

- [ ] **Step 3: Make the plain paths collect-all-then-fail.**

  `analyzer` is local to `analyzeWithOptions` and is freed by its own `defer analyzer.deinit()`; it is **not** returned (the call sites receive only `ir.Module`, which has no `errors` field). So you **cannot** inspect `analyzer.errors` from the `root.zig` call sites. There are exactly two viable seams — pick ONE:

  **(a) New strictness flag on the in-analyzer gate (recommended).** Add `fail_on_recorded_errors: bool = false` to `AnalyzeOptions` (`src/semantic.zig:56`). At the gate (`src/semantic.zig:113`), change to:
  ```zig
  if ((!analyzer.tolerate_errors or options.fail_on_recorded_errors) and analyzer.errors.items.len > 0)
      return error.SemanticFailed;
  ```
  Then `compileToSPIRV` (`:344`) and `compileToSPIRVNoOpt` (`:511`) pass `.tolerate_errors = true, .fail_on_recorded_errors = true` — every statement error is still *collected* (tolerate path, no fail-on-first), but analysis fails if any was recorded. `compileToSPIRVWithDiagnostics` keeps `.fail_on_recorded_errors = false` so its own `:1042-1048` drain-then-fail loop remains the single failure decision for that API (no behavior change there).

  **(b) Register a sink in the plain paths and reuse the `:1042-1048` loop.** Have `compileToSPIRV`/`NoOpt` set `semantic.diag_sink` (mirroring `root.zig:986-988`), run the same error-kind loop over the drained diagnostics, then restore the sink. This literally hoists the proven check — but note the missing mechanical step the implementer must add: **the plain path must set the sink itself**, which today it does not.

  Prefer **(a)**: less code, no threadlocal-sink re-entrancy surface, and the failure decision stays in one place.

  **Critical:** preserve multi-error collection (do NOT regress to fail-on-first `src/semantic.zig:106`) and do NOT change `compileToSPIRVWithDiagnostics` behavior (it must still drain ALL diagnostics before failing — verify with its existing tests).

- [ ] **Step 4: Verify the flip + the whole suite.**

  ```bash
  mise exec -- zig build test --summary all     # both flip tests pass; ZERO other regressions
  ```
  Expected: green. **Any newly-failing previously-passing test is a residual false-positive — STOP, return to Task 1 for that construct, do not weaken the flip.**

- [ ] **Step 5: Add the continuous strict gate (spec-mandated — nothing else stops a NEW false-positive from regressing in after the flip).**

  Post-flip the enumerator's tolerate-vs-strict signal collapses (tolerate now *is* strict), so the continuous guard is a different shape: walk the curated-valid corpus, compile each fixture with `compileToSPIRV`, and **exit non-zero on any rejection that is NOT in `KNOWN_UNSUPPORTED`** — a curated-valid fixture newly rejected is, by definition, a false-positive regression. Add this as a `--strict-gate` mode to `tests/runner.zig` (reuse the suite walk; skip `spirv-val`), a `just strict-gate` recipe, and include it in the `just ci` recipe (`ci: test test-hlsl validate-dxc strict-gate`). This cheaply enforces Done-bar #4 on every run; the full `glslang -V` differential stays the one-time Acceptance #5 sweep, and any fixture `--strict-gate` flags must be `glslang -V`-checked during triage (glslang-accepts → real regression; glslang-rejects → add to `KNOWN_UNSUPPORTED`).

- [ ] **Step 6: Commit.**

  ```bash
  git add src/root.zig src/semantic.zig tests/runner.zig justfile tests/analyzer_strict_tests.zig
  git commit -m "feat(api): compileToSPIRV/NoOpt fail loud on recorded errors + continuous strict gate"
  ```

---

## Task F3 — Conformance XFAIL for the 7 known-unsupported fixtures

**Why:** the flip converts the 7 known fails from `.fail` (spirv-val, invalid output) to `.compile_error` (honest reject). The runner exits 1 on `compile_error > 0` (`tests/runner.zig:335`), so without an XFAIL list, conformance would go red. These are *expected* honest rejections of unrepresentable valid GLSL.

**Files:** `tests/runner.zig`

- [ ] **Step 1: Add the known-unsupported XFAIL list + an `xfail` stat.**

  In `tests/runner.zig`, add `xfail: u32 = 0` to `Stats`, add `+ self.xfail` to `Stats.total()` (`tests/runner.zig:15-17` — otherwise TOTAL undercounts by the XFAIL count), and add a const list of the 7 fixture paths:
  ```zig
  const KNOWN_UNSUPPORTED = [_][]const u8{
      "tests/spirv-cross/fp64.desktop.comp",
      "tests/spirv-cross/int64.desktop.comp",
      "tests/glslang-430/newTexture.frag",
      "tests/glslang-430/spv.newTexture.frag",
      "tests/spirv-cross/shader_ballot.comp",
      "tests/spirv-cross/ray_sphere_test.frag",
      "tests/spirv-cross/struct-material.frag",
  };
  // Match the FULL repo-relative path (the runner builds full_path as
  // "{dir_path}/{entry.path}", tests/runner.zig:204). Matching the bare basename
  // would over-match — "newTexture.frag" is a suffix of ".../spv.newTexture.frag".
  fn isKnownUnsupported(path: []const u8) bool {
      for (KNOWN_UNSUPPORTED) |p| if (std.mem.endsWith(u8, path, p)) return true;
      return false;
  }
  ```

- [ ] **Step 2: Reclassify in the result switch.**

  In `runDir`'s switch (`tests/runner.zig:207`), when `result == .compile_error` (or `.fail`) AND `isKnownUnsupported(full_path)`, increment `stats.xfail` instead and log `XFAIL` — these are expected honest rejections, not regressions.

- [ ] **Step 3: Update the summary + exit gate.**

  Print `XFAIL: {d}` in the summary (`:328`). Change the exit gate (`:335`) to `if (stats.fail > 0 or stats.compile_error > 0)` — now that the 7 are counted as `xfail`, both should be 0 and the suite exits 0. Add a guard that fails if a KNOWN_UNSUPPORTED fixture unexpectedly *passes* (it was fixed — remove it from the list).

- [ ] **Step 4: Verify conformance is green.**

  Run: `just test-conformance` — Expected: `PASS 2080 / FAIL 0 / XFAIL 7 / SKIP 8`, **exit 0**.

- [ ] **Step 5: Commit + update docs.**

  Update `docs/TEST_COVERAGE.md` and `docs/IMPLEMENTATION_STATUS.md`: the 7 are now *expected honest rejections* (XFAIL), suite exits 0.
  ```bash
  git add tests/runner.zig docs/TEST_COVERAGE.md docs/IMPLEMENTATION_STATUS.md
  git commit -m "test(conformance): XFAIL the 7 known-unsupported fixtures (honest rejections, suite exits 0)"
  ```

---

## Acceptance (the empirical Done-bar)

The milestone is complete only when **all** hold:

1. `just test` green (pin the live baseline at execution time — it was 2,060/2,060 on 2026-05-31; it moves as tests land).
2. `just test-hlsl` green.
3. `just test-conformance` → `2080 PASS / 0 FAIL / 7 XFAIL / 8 SKIP`, exit 0.
4. `just enumerate-fp` reports **zero** false-positive candidates.
5. **Oracle sweep:** a `glslangValidator -V` differential over the conformance corpus shows **zero** cases where glslpp rejects what glslang accepts. (Within-corpus only — residual risk for valid GLSL outside the corpus is documented; honest errors name the construct + line so any post-flip false-positive is an obvious, reportable bug, and `compileToSPIRVNoOpt` remains as a bisect escape hatch — per the spec's residual-risk note.)
6. wintty's production shaders still compile (run wintty's shader build against the new glslpp).

Any regression in 1–6 is a **STOP**: the flip is gated behind a clean bar; do not weaken it to go green.

---

## Self-review notes

- **Spec coverage:** Task 0 = enumeration harness + classification rule; Task 1 = model false-positives (cascade dedup via re-run); F1 = honest-error for unrepresentable; F2 = the flip (hoisting `root.zig:1042-1048`, both entry points); F3 = XFAIL accounting. Every spec section maps to a task.
- **Discovery-driven middle is intentional, not a placeholder:** Task 1 is an explicit repeatable template because the spec mandates Task 0 produce the real worklist; its RED/verify/commit steps are fully concrete, and the per-construct GREEN is read-and-edit work that cannot be pre-written against an unknown construct. Re-run `writing-plans` after Task 0 if the worklist warrants per-bucket numbered tasks.
- **No silent-wrong:** every GREEN is gated on spirv-val + glslang `-V`; F1 forbids OpUndef/truncation; F2 forbids weakening the flip to pass.
- **Type/name consistency:** `compileToSPIRVStrict`, `enumerate-fp`, `strict_fp`, `KNOWN_UNSUPPORTED`, `isKnownUnsupported`, `xfail` are used consistently across tasks.
