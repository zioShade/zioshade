# Spec: Arbitrary-SPIR-V CFG structurization (G2)

Status: **draft / design** — 2026-06-02. Author: glslpp maintainer.
Tracks backlog item #4 ("Arbitrary-SPIR-V ingestion: structurize unstructured CFG").

## 1. Problem

glslpp's cross-compilers (`src/spirv_to_{glsl,hlsl,msl,wgsl}.zig`) reconstruct
high-level control flow (`if` / `switch` / loops) by reading SPIR-V's **structured
control-flow** instructions: `OpSelectionMerge` and `OpLoopMerge`. These name, for
each header block, the *merge* block (where the construct rejoins) and — for loops
— the *continue* block.

SPIR-V emitted by glslpp's own front end always carries this merge info. But SPIR-V
from **external** producers — `glslangValidator`/`spirv-opt` after aggressive passes,
DXC, hand-written `.spvasm` — may be **unstructured**: an `OpBranchConditional` or
`OpSwitch` with **no** preceding `OpSelectionMerge`, back-edges with no `OpLoopMerge`,
or genuinely **irreducible** graphs (multiple-entry loops) that SPIR-V's structured
form cannot even express.

Today (correctly, per Mitchell discipline) every backend **fails loud** with
`error.UnstructuredControlFlow` when it hits a conditional/switch lacking merge info
(`spirv_to_glsl.zig:1249/1283`, `spirv_to_hlsl.zig:2428/2467`,
`spirv_to_msl.zig:2342/2373`, and the WGSL replay path). This is a *safe* state — no
silent-wrong — but it means glslpp is not yet a drop-in for arbitrary SPIR-V.

**Goal:** ingest unstructured-but-reducible SPIR-V by *recovering* the merge/continue
structure, while continuing to honest-error the genuinely-irreducible minority.

## 2. Key decision: one pre-pass, not four backend rewrites

Merge info is consumed identically by all four backends. Therefore structurization
MUST be a **module-level pre-pass** that runs on the parsed SPIR-V *before* any
backend, and whose only output is a module in which every `OpBranchConditional`/
`OpSwitch` that needs it is preceded by a synthesized `OpSelectionMerge`/`OpLoopMerge`
naming the correct blocks. After the pass, the existing backends work unchanged.

This keeps the risky logic in ONE place, gated by ONE set of oracle tests, and means
a bug can only ever produce SPIR-V that the backends then either compile correctly or
honest-error on — never silent-wrong (see §5).

Placement: a new `src/cfg_structurize.zig`, invoked from the cross-compile entry
points (or from a shared "normalize module" step) only when a backend would otherwise
hit the unstructured path. Cheap fast-path: if the module already has merge info for
every multi-successor block (the glslpp-native case), the pass is a no-op.

## 3. Algorithm (reducible CFGs)

Standard structured-control-flow recovery, per function:

1. **Build the CFG.** Nodes = basic blocks (`OpLabel`…terminator). Edges from
   `OpBranch` / `OpBranchConditional` / `OpSwitch`. Entry = the function's first block.
2. **Dominator tree** (Cooper–Harvey–Kennedy iterative algorithm — simple, fast,
   no external deps).
3. **Post-dominator tree** (dominators on the reverse CFG with a virtual exit node
   that all `OpReturn`/`OpKill`/`OpUnreachable` blocks point to).
4. **Identify loop headers:** a block that is the target of a **back-edge** (an edge
   `b → h` where `h` dominates `b`). For each loop header `h`:
   - *continue block* = the back-edge source's side that the loop latch sits on
     (the predecessor of `h` inside the loop with the back-edge); for the common
     single-latch case it is that latch block.
   - *merge block* = the loop's break target = the immediate post-dominator of `h`
     restricted to blocks outside the loop body (the unique block all
     loop-exit edges converge on). Synthesize `OpLoopMerge %merge %continue None`.
5. **Identify selection headers:** a block ending in `OpBranchConditional`/`OpSwitch`
   that is **not** a loop header. Its *merge block* = its immediate post-dominator.
   Synthesize `OpSelectionMerge %merge None`.
6. **Reducibility check:** if any loop has **multiple entries** (a back-edge target
   that does not dominate all its loop's blocks), or a selection header whose
   immediate post-dominator is the virtual exit only because of an early `OpReturn`
   inside one arm (no real convergence) in a way that can't be expressed structurally,
   the graph is **irreducible / non-structurable** → **honest-error**
   `error.UnstructuredControlFlow` with the offending block id in the detail. NEVER
   guess.

The synthesized merge/continue ids reference EXISTING blocks (no new blocks in the
first phase — see §6 for when node-splitting/duplication is needed). Insert the
`OpSelectionMerge`/`OpLoopMerge` immediately before the header's branch terminator.

## 4. Why post-dominator = merge block

For a structured single-entry/single-exit region, the merge block is exactly the
nearest common post-dominator of the header's successors. Using the post-dominator
tree's immediate-post-dominator of the header gives this directly for the
well-behaved (reducible, no cross-arm gotos) case. Cases where the ipdom is *not* a
valid structured merge (e.g., one arm returns, the other falls through; or arms share
code via a goto) are precisely the ones we must detect and honest-error rather than
mis-merge.

## 5. Safety / oracle strategy (the whole point)

This is silent-wrong-prone, so the test gate is non-negotiable:

- **Round-trip property test:** for a corpus of structured shaders, *strip* their
  merge instructions, run the structurizer, and assert it **re-derives byte-identical
  merge/continue assignments** (or an equivalent set that produces the same backend
  output). This directly tests correctness against known-good answers.
- **Oracle differential:** take external/optimized SPIR-V (run our own shaders through
  `spirv-opt -O` to perturb structure), structurize, cross-compile, and validate the
  result with the backend oracle (glslang -V / dxc / naga) AND check the SPIR-V is
  still `spirv-val`-clean. Any divergence → bug.
- **Conformance must not regress:** the pre-pass no-ops on glslpp-native SPIR-V
  (already structured), so `just test-conformance` (2074 PASS / 0 FAIL) MUST be
  byte-unchanged. Gate this explicitly.
- **Irreducible corpus:** a handful of hand-written irreducible `.spvasm` fixtures
  that MUST honest-error (never silently miscompile).

If the round-trip test cannot prove a pattern correct, that pattern stays on the
honest-error path. Coverage grows by *moving* patterns from honest-error to handled,
each move gated by a green round-trip + oracle test.

## 6. Phasing (each phase = one mergeable, oracle-gated PR)

- **Phase 0 (this spec).** Design + safety strategy. ✅
- **Phase 1 — analysis scaffold + reducibility classifier.** `cfg_structurize.zig`:
  CFG build, dominator + post-dominator trees, back-edge/loop-header detection,
  reducibility predicate. NO mutation yet. Unit tests on small CFGs with known
  dom/pdom answers. Wire a `--classify-cfg` debug path. Zero behavior change.
- **Phase 2 — selection merge recovery.** Synthesize `OpSelectionMerge` for reducible
  `if`/`switch` headers; honest-error otherwise. Gate: strip-and-recover round-trip on
  the conformance corpus is byte-identical; `spirv-opt`-perturbed differential green.
- **Phase 3 — loop merge/continue recovery.** Same for `OpLoopMerge`. Hardest case
  (continue-block identification, nested loops). Same gates.
- **Phase 4 — node-splitting for the reducible-but-shared-tail cases** (optional;
  duplicate a shared merge tail when two arms converge early). Only if a real corpus
  needs it; otherwise these stay honest-errored.
- **Irreducible** (multi-entry loops): out of scope — permanently honest-error
  (matches what structured SPIR-V itself cannot represent).

## 7. Non-goals

- Optimizing the recovered structure (we recover *a* valid structure, not the
  prettiest).
- Handling SPIR-V features orthogonal to CFG (those have their own honest-error paths).
- Changing any backend's emit logic — the pre-pass makes external SPIR-V look like
  glslpp-native SPIR-V to the backends.

## 8. Acceptance (when #4's DoD bullet "arbitrary SPIR-V works" is met)

- `spirv-opt -O`-perturbed versions of the conformance corpus cross-compile and pass
  the backend oracles (or honest-error on a documented irreducible minority).
- Strip-and-recover round-trip is byte-identical on the structured corpus.
- `just test-conformance` unchanged (pre-pass no-ops on native SPIR-V).
- Irreducible fixtures honest-error with a block-id detail; zero silent-wrong.
