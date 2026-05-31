# Analyzer Fail-Loud — Design Spec (2026-05-31)

> **Status:** approved design, pending implementation plan (`writing-plans`).
> **Origin:** keystone item from the 2026-05-31 "what's left for world class" assessment — Layer 1 (Trust & integrity).

## Goal

Make the plain `compileToSPIRV` API **fail loud** (`error.SemanticFailed`) on genuinely-broken
shader input, instead of running the semantic analyzer in `tolerate_errors=true` mode where
recorded errors are swallowed and codegen proceeds to emit possibly-invalid SPIR-V at exit 0.

The blocker is **not** the fail-loud switch itself — it is the **~45+ analyzer false-positives**
(valid GLSL the analyzer over-rejects, masked today because tolerate mode lets codegen handle
them anyway). Flipping fail-loud before those are gone would falsely reject valid shaders. So the
milestone is: **eliminate the false-positives, then flip.**

This also closes the **Bug #3.B footgun**: `compileToSPIRVWithDiagnostics` is already fail-loud
(contract landed in `8ee39335`, polished through `362c7cf4`) and can therefore *falsely* return `error.SemanticFailed` for a valid shader
that uses an over-rejected construct (e.g. `outerProduct`). Eliminating false-positives makes both
APIs trustworthy.

## Non-goals

- **Not** a push for full Khronos GLSL coverage. We model only what the empirical corpus +
  `glslang -V` oracle prove is needed (see Done-bar).
- **Not** a fp64/int64/double type-system project. Genuinely-unrepresentable valid GLSL gets an
  **honest error**, not a model. fp64/non-square-matrix work is pulled in *only if* Task 0 surfaces
  it as a real false-positive (valid GLSL + correct output reachable), which for fp64 it is not.
- **Not** a rewrite of the diagnostic plumbing — `diag_sink` (`semantic.zig:34`) and the
  collect-all machinery already exist and are reused.

## Background — current mechanism (accurate as of this worktree)

| Symbol | Location | Role |
|---|---|---|
| `AnalyzeOptions.tolerate_errors` | `src/semantic.zig:60` | when true, analyzer records errors and keeps going |
| `analyzeWithOptions` | `src/semantic.zig:77` | entry; loops top-level decls |
| function-level catch | `src/semantic.zig:106` | `if (!tolerate_errors) return err;` — **strict mode fails on FIRST error** |
| collect-then-fail gate | `src/semantic.zig:113` | `if (!tolerate_errors and errors.len > 0) return error.SemanticFailed;` |
| `analyzeFunction` | `src/semantic.zig:1999` | per-statement analysis |
| per-statement tolerate path | `src/semantic.zig:2084` | `if (self.tolerate_errors) { … continue; }` (the `break`→`continue` fix, Bug #3) |
| diagnostic recording | `src/semantic.zig:2103` | `if (diag_sink) |sink| …` records one diagnostic per tolerated stmt error |
| `diag_sink` | `src/semantic.zig:34` | threadlocal; null for plain `compileToSPIRV` (zero behavior change) |
| plain-compile entry points | `compileToSPIRV` → `src/root.zig:344`; `compileToSPIRVNoOpt` (`:486`) → `src/root.zig:511` | **two distinct functions**, both pass `.tolerate_errors = true` ← **the flip points** |
| `compileToSPIRVWithDiagnostics` | `src/root.zig:974` | sets `diag_sink` (`:986-988`); already fail-loud via the error-kind loop at `:1042-1048` (contract landed `8ee39335`, polished `362c7cf4`) |

**Three strictness behaviors exist today:**

1. `tolerate_errors=false` → returns on the **first** error (`:106`). Used by `gap_tests.zig`.
2. `tolerate_errors=true`, no sink → **collect, never fail** (today's plain `compileToSPIRV`).
3. `tolerate_errors=true` + `diag_sink` + fail-loud contract → **collect all, then fail** if any
   error-kind diagnostic (today's `compileToSPIRVWithDiagnostics`).

**Desired end-state for both plain entry points (`compileToSPIRV` `:344`, `compileToSPIRVNoOpt` `:511`)
is behavior #3 without requiring the caller to pass a sink** — collect every error (good
diagnostics), then fail if any genuine error was recorded. The flip is therefore *not* simply
`tolerate_errors = false` at those sites (that would revert to fail-on-first-error #1 and lose
multi-error collection). **The reference implementation already exists**: the error-kind loop at
`root.zig:1042-1048` (inside `compileToSPIRVWithDiagnostics`) does exactly "collect-all-then-fail"
over the drained diagnostics. The preferred flip is to **hoist that check into the plain path**
rather than invent a new `AnalyzeOptions` strictness enum (more invasive, risks reintroducing
fail-on-first #1) — but the exact mechanism is a plan-level decision.

## Architecture — two phases

### Phase A — Enumerate & eliminate (the bulk)

**Task 0 (load-bearing): the strict-mode enumeration harness.**
A repeatable tool/build-flag that runs analysis in "fail on any recorded error even in tolerate
mode" across all four corpora and emits a **categorized worklist** of every shader that newly
fails. This is the memory's one-off "blast-radius experiment" promoted to a reproducible tool.
**Its output is the real spec input** — the category list below is a *hypothesis*; Task 0 produces
ground truth (counts per category, exemplar fixtures, cascade vs. root-cause dedup).

**Dedup heuristic (so counts are trustworthy, not asserted):** cascade poisoning means one
unmodeled `var_decl` initializer makes its declared var "undeclared" in every later statement,
inflating a single root cause into N phantom errors. Task 0 therefore counts **only the
first error per function** for the worklist ranking, and **re-runs the whole harness after each
category is modeled** to measure the *true* remaining blast-radius rather than trusting the initial
N. The "~45+" figure from the prior one-off experiment is treated as an upper bound to shrink, not a
fixed task count.

**The classification rule (the safety mechanism).** For each newly-failing shader, the oracle is
`glslangValidator.exe -V` (Vulkan SPIR-V target = what glslpp emits;
`C:/VulkanSDK/1.4.341.1/Bin/`):

| glslang `-V` verdict | glslpp can represent? | Action |
|---|---|---|
| **accepts** | yes | **FALSE-POSITIVE** → model it (analyzer accepts **and** codegen emits spirv-val-clean output) |
| **accepts** | no (e.g. fp64/int64) | **honest "unsupported" error** — strictly better than today's silently-invalid SPIR-V |
| **rejects** | n/a | **TRUE rejection** → keep the error (already correct; registering would be silent-wrong) |

This rule is the existing project methodology (memory: "audit every false-positive against
`glslang -V` before registering"). It is the single guardrail that keeps the milestone from
trading over-rejection for silent-wrong over-acceptance.

**Tasks 1..N — one per false-positive category, strict TDD**, ordered by **corpus frequency**
(highest blast-radius first). Each task: RED (a valid-GLSL fixture the analyzer over-rejects) →
GREEN (model it) → verify with **spirv-val AND glslang `-V`** (never string-match alone — the
false-green trap). Candidate categories from memory, **to be confirmed/re-ranked by Task 0**:

- non-square matrix ops (`mat3x4 * vec4`, etc.)
- array/struct constructors + arrays-of-arrays
- swizzle-write lvalues to SSBO members (`p[id].vel.xyz += …`)
- for-update comma operators / compound assignment in `continue_stmt`
- **cascade poisoning** — one unmodeled `var_decl` initializer makes the declared var
  "undeclared" in every later statement (one gap rejects a whole function). Modeling must degrade
  gracefully so a single unknown doesn't fan out into dozens of phantom false-positives.
- remaining valid builtins glslang `-V` accepts (continuation of the `8fadc0c0` triage; most are
  already done — `matrixCompMult`, `gl_PointCoord`, `interpolateAt*`).

**Honest-error pass (genuinely-unrepresentable).** fp64/int64 and any other valid-but-unrepresentable
construct get a clean `error.Unsupported*` with line/col, matching the `literalWord` precedent
(overflowing 64-bit literal → honest error, never silent-truncate).

### Phase B — Flip (small, gated)

Change **both** plain-compile entry points (`compileToSPIRV` `:344`, `compileToSPIRVNoOpt` `:511`)
to the **collect-all-then-fail** behavior (#3) by hoisting the proven error-kind check from
`root.zig:1042-1048`. (Confirm there are no other `tolerate_errors = true` plain sites — currently
exactly these two.) Removes the tolerate escape hatch for genuine errors while keeping multi-error
diagnostics. Eliminates the Bug #3.B false-positive footgun automatically (same recorded-error set,
now trusted).

## Key interaction — conformance accounting

The flip converts the **7 known conformance failures** from "emit invalid SPIR-V (FAIL spirv-val)"
into "honest compile error (FAIL compile)":

`fp64.desktop.comp`, `int64.desktop.comp` (64-bit types) · `newTexture.frag`, `spv.newTexture.frag`
(OpExtInst word-count) · `shader_ballot.comp` · `ray_sphere_test.frag` · `struct-material.frag`.

This is an **improvement** (no more silently-invalid output) but changes accounting. The milestone
therefore adds an **XFAIL / known-unsupported list to `tests/runner.zig`** so these genuinely-
unrepresentable constructs count as *expected honest rejections*, not regressions. Conformance
acceptance becomes: **2,080 PASS + 7 expected-honest-XFAIL**, suite exits 0 (no unexpected fail).

## Done-bar (empirical "corpus + oracle clean")

The flip ships only when **all four** are clean:

1. `just test` green — a distinct suite from conformance (baseline 2,054/2,054 as of 2026-05-31;
   pin the live value at plan time, it moves as tests land).
2. `just test-hlsl` green (793/793 as of 2026-05-31).
3. Conformance = 2,080 PASS + 7 expected-XFAIL honest rejections (no unexpected FAIL).
4. **`glslang -V` differential sweep over the corpus shows ZERO cases where glslpp rejects what
   glslang accepts** (the operational definition of "no false-positives *within the corpus*"), AND
   wintty's real production shaders still compile.

A construct that is neither modeled nor oracle-confirmed-invalid is **not** allowed to ship as a
silent pass — it is either modeled (false-positive) or honest-errored (unrepresentable/true-reject).

**Residual risk (must document at ship time):** done-bar #4 proves "no false-positives" only
*within the four corpora* — valid GLSL outside them can still hit a post-flip `error.SemanticFailed`
where today it got (possibly-valid) SPIR-V. This is acceptable and strictly safer than silent-wrong,
but the flip MUST land with two mitigations: (a) every honest-error path **names the construct +
line/col** so a post-flip false-positive is an obvious, reportable "glslpp rejects valid X" bug
(never a silent miscompile); (b) keep `compileToSPIRVNoOpt` (or a documented escape hatch) so a
consumer hitting a novel false-positive can bisect/work around it until it's modeled.

## Risks

| Risk | Mitigation |
|---|---|
| **Mis-modeling a construct = silent-wrong** (worse than over-rejecting) | Every GREEN verified with spirv-val **and** glslang `-V`; no string-match-only assertions |
| **Cascade poisoning inflates the worklist** | Task 0 dedups to root causes; modeling degrades gracefully so one unknown ≠ N phantom errors |
| **Flip changes the 7 conformance fails' bucket** | XFAIL list in `tests/runner.zig`; acceptance counts honest rejection as expected |
| **wintty regression** (the actual consumer) | wintty shaders are part of the Done-bar corpus, gated before flip |
| **`gap_tests.zig` is not in the build** (`src/root.zig:1054`) | Task-0 harness + per-construct fixtures live in built `tests/*.zig` or inline, not `gap_tests.zig` |

## Testing strategy

- **Task 0 harness** is itself a tool with a regression test asserting it enumerates a known
  seeded false-positive.
- **Per-construct:** strict TDD, RED valid-GLSL fixture → GREEN model → spirv-val + glslang-oracle.
- **Strict-mode regression test:** asserts the corpus yields **zero** glslpp-rejects-glslang-accepts
  (wire into `just` so the Done-bar #4 is continuously enforced after the flip).
- **No silent caps:** if Task 0 bounds the corpus (sampling, top-N), `log` what was dropped.

## Open implementation-level decisions (deferred to the plan)

- Exact flip mechanism: **preferred** = hoist the proven error-kind check from `root.zig:1042-1048`
  into both plain entry points; **alternative** = a new `AnalyzeOptions` strictness enum (more
  invasive, risks fail-on-first #1). Plan picks one.
- Where the strict-mode harness lives: a `-D` build option on the conformance runner vs. a
  standalone `tools/` tool.
- Task ordering finalized from Task 0's real frequency counts (not the hypothesis list above).
