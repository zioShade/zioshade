# Architecture

A contributor's map to the codebase. For scope/limitations see
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md); for conformance counts see
[STATUS.md](STATUS.md); for the correctness methodology see
[DIFFERENTIAL_PROOF.md](DIFFERENTIAL_PROOF.md) and [COVERAGE_MATRIX.md](COVERAGE_MATRIX.md).
This doc is about *how the code is laid out and how to navigate it*.

zioshade is two compilers sharing one IR:

```
GLSL source
  -> lex -> preprocess (token-based) -> parse (AST) -> semantic (IR) -> codegen (SPIR-V) -> optimize
                                                                          |
   (SPIR-V is the interchange IR for everything below)                    v
                                                          cross-compiler backends
                +----------------+----------------+----------------+----------------+
                v                v                v                v
              HLSL             MSL              GLSL             WGSL
```

Reflection, the C ABI, and the WASM target all sit on top of the SPIR-V IR as well.

## Module map (`src/`)

| File | Role |
|---|---|
| `preprocessor.zig` | `#define`/`#if`/`#include`/`#extension` macro expansion |
| `lexer.zig` | GLSL tokenization |
| `parser.zig` + `ast.zig` | GLSL -> AST |
| `semantic.zig` | AST -> IR (`ir.Module`): types, decorations, control flow, builtin resolution |
| `ir.zig` | The IR module types (the shared structure codegen and the backends both consume) |
| `codegen.zig` | IR -> SPIR-V. `generate` runs the optimizer; `generateNoOpt` emits the faithful IR |
| `compact_ids_passes.zig` | The SPIR-V optimizer passes (~12.7k LOC; the largest single file) |
| `compact_ids.zig` | ID compaction (renumber after passes mutate the module); `getOpInfo` (per-opcode operand layout, used by backends + optimizer) |
| `loop_counter_phi.zig`, `inline_multiblock.zig`, `fold_extract_construct.zig` | Specialized passes |
| `cfg_structurize.zig` | Best-effort pre-pass run by every backend: recovers missing `OpSelectionMerge` for reducible unstructured `if`/`switch` (selection only) |
| `spirv_to_hlsl.zig` / `_msl.zig` / `_glsl.zig` / `_wgsl.zig` | The four cross-compiler backends |
| `spirv_cross_common.zig` | Shared backend helpers (`emitBinOp`/`emitCall`, decoration handling) |
| `spirv.zig` | The SPIR-V enums: `Op`, `Capability`, `BuiltIn`, `StorageClass`, `Decoration`, `ExecutionMode`, `GLSLstd450` |
| `reflection.zig` | Enumerate UBO/SSBO/sampler/IO resources + JSON from a SPIR-V module |
| `kernel_fusion.zig` | Merge compute shaders / link SPIR-V modules |
| `diagnostic.zig` | The `Diagnostic` struct behind `compileToSPIRVWithDiagnostics` |
| `root.zig` | The public API (`compileToSPIRV`, `spirvToHLSL/MSL/GLSL/WGSL`, `reflectSPIRV`, ...) |
| `cli.zig` | The `zioshade` command-line tool |
| `c_abi.zig` | The C ABI (`include/zioshade.h`, `zig build c-lib`) |
| `wasm.zig` | The WebAssembly target |
| `compat.zig` | Zig 0.15.2 <-> 0.16 runtime version shims (capability-detected via `@hasDecl`, never version-number-gated) |

Also in `src/`: `gap_tests.zig` and `opt_matvec.zig` are dev/experimental (`opt_matvec.zig`'s
`optimizeMatVecMul` is currently unwired). `build_compat.zig` is the build-time companion to
`compat.zig` but lives at the **repo root** (imported by `build.zig`), not in `src/`.

The backends are the four biggest files (~34k LOC together); they are independent emitters
that each walk the SPIR-V module instruction-by-instruction and emit target source.

## The GLSL -> SPIR-V frontend

`compileToSPIRV` (root.zig) drives: `lexer` -> `preprocessor` -> `parser` -> `semantic`
(builds an `ir.Module`) -> `codegen.generate` (SPIR-V bytes, optimized) or
`codegen.generateNoOpt` (faithful, unoptimized). The preprocessor is **token-based** -- it
runs on the lexer's token stream (expanding `#define`/`#if`/`#include`), not as a text
substitution pass -- hence lex before preprocess. `generateNoOpt` exists so a caller can
prove correctness on the *unoptimized* IR -- some miscompiles only surface on one path
(the `#loop-continue-deadincr` class was invisible on optimized SPIR-V; `prove_naga`
exercised it on the unoptimized path).

The `Op` enum in `spirv.zig` is the set of SPIR-V opcodes zioshade models (257 today; see
[COVERAGE_MATRIX.md](COVERAGE_MATRIX.md)). Frontend constructs zioshade cannot translate
faithfully are **honest-errors** (`error.CodegenFailed` / `error.SemanticFailed`), never
silent-wrong output.

## The optimizer pipeline

`codegen.generateInternal` (codegen.zig) runs the passes in a fixed order on the raw SPIR-V
bytes. Grouped by purpose (the exact sequence is in `generateInternal`):

1. **Access chains + early DCE**: `mergeAccessChains`, `deadCodeElim`, `elimTrivialEntryPoint`, `deadLoopElim`, `elimUnreachableCalls`.
2. **Inlining**: `inlineTrivialFuncs` -> `moveVarToEntry` -> DCE -> `compactIds`; then `elimDeadVoidCalls`, `elimDeadFunctions`.
3. **Phi recovery**: `loopCounterToPhi`, `branchMergePhi`, `simplifyTrivialPhi` (so optimized loops lower to the phi form backends expect).
4. **Store forwarding + block merging**: `redundantStoreElim`, `mergeBlocks`, `mergeNonEmptyBlocks`, `hoistInvariantACs`.
5. **Multi-block inlining**: `inlineMultiBlock` + block merges + DCE.
6. **Type dedup** (`dedupStructTypes`), then **arithmetic simplification**: `elimSelfRefArithmetic`, `eliminateDoubleNegate`, `foldNegateIntoAddSub`, `algebraicSimpl` (the identity-fold + transitive closure -- see `optimizer_tests.zig`), `constFold`, `foldSelect`.
7. **Control flow**: `foldConstBranches`, `elimUnreachableBlocks`, `simplifyTrivialPhi`, `compactIds`.
8. **Memory**: `elimRedundantLoads`, `cseWithinBlocks`; **composite**: `foldConstCompositeExtract`, `foldCompositeExtract`, `foldShuffleFromComposite`, `foldExtractConstructToShuffle`, `elimIdentityShuffle`.
9. **Variables**: `elimUninitVars`, `constStoreForward`, `fixEarlyAccessVars`; **store-to-composite**: `scatterStoreToComposite`, `storeForwardExtract`.
10. **Final cleanup**: `elimDeadVarStores`, DCE, `retargetEmptyBlocks`, CSE, DCE, `elimIdentityStores`, DCE, `compactIds`. (`copyMemoryOpt` is **disabled** -- it produced undefined IDs after DCE and also hung on some shaders; see the comment in `generateInternal`.)
11. **Import/global cleanup**: `elimUnusedImports`, DCE, compactIds, `elimUnusedGlobals`, DCE, `stripDeadDebugInfo`, DCE, compactIds.
12. **Final type dedup**: `dedupArrayTypes`, `dedupStructTypes`, `dedupPointerTypes`, `dedupFunctionTypes`, DCE, `ensureLoopPreheader` (a function whose entry block is a loop header gets a pre-header so it is never a branch target), `compactIds`.

Every pass is `fn(alloc, words) error{OutOfMemory}![]const u32` -- a pure transform of the
SPIR-V word stream; on allocation failure it returns the input unchanged (the "never
miscompile, degrade gracefully" rule). Post-optimizer validity is the conformance
`strict-gate`'s job: spirv-val on every fixture, 0 FP-regression. (`hasMalformedCFG`
validates the RAW frontend output *before* optimization -- see the honest-error section; it
is not a per-pass gate.)

## The cross-compiler backends (SPIR-V -> HLSL / MSL / GLSL / WGSL)

Each backend entry (`spirvToHLSL` etc.) first runs `cfg_structurize`'s `structurizeModule`
-- a **best-effort, selection-merge-only** pre-pass. It recovers missing `OpSelectionMerge`
for reducible unstructured `if`/`switch` (a no-op on already-structured input, which is
everything zioshade's own frontend emits); loop-merge recovery is intentionally not composed
yet. It is invoked as `structurizeModule(...) catch null` -- on failure the backend silently
falls back to the original words, so the structurizer's `error.UnstructuredControlFlow` is
not what stops a bad module. The actual fail-loud for unstructured **loops** (missing
`OpLoopMerge`) and irreducible CFGs happens later, in the backend's own per-instruction
loop/switch lowering -- never a miscompile.

The backend then walks the module and dispatches per instruction (`switch (inst.op)` in the
main emit function), emitting target source. Shared logic lives in `spirv_cross_common.zig`
(`emitBinOp`/`emitCall`, decoration handling); per-opcode operand layout comes from
`compact_ids.getOpInfo`. An opcode a backend cannot faithfully lower is an honest-error --
but the precise contract is per-backend, and a contributor chasing a silent-wrong needs to
know it: **WGSL** fails loud unconditionally (`error.UnsupportedOp`); **GLSL**
(`error.CrossCompileUnsupported`) and **HLSL/MSL** (`error.UnsupportedOpcode`) fail loud only
when the unhandled opcode's result is actually *consumed*, and otherwise emit a visible
`// unhandled op N` stub comment for the (dead) result. So an unhandled opcode never produces
silent-wrong output, but dead results get a stub rather than an error, and the error names
differ across backends.

## The honest-error contract, and where it is enforced

The one rule (see [AGENTS.md](../AGENTS.md)): **never emit plausible-but-wrong output.** It
is enforced at three layers:

- **Codegen (raw frontend output)**: `hasMalformedCFG` validates the SPIR-V the frontend
  just emitted -- a block with no terminator, or a branch/merge targeting id 0 -- *before*
  optimization; untranslatable GLSL is `error.CodegenFailed` / `error.SemanticFailed`.
- **Optimizer**: each pass degrades to "return input unchanged" on any allocation failure;
  `strict-gate` (spirv-val on every fixture, 0 FP-regression) is the post-optimizer backstop.
- **Backends**: per-opcode honest-errors -- WGSL `UnsupportedOp`; GLSL `CrossCompileUnsupported`;
  HLSL/MSL `UnsupportedOpcode` -- fail loud when an unhandled opcode's result is consumed
  (see "The cross-compiler backends" for the per-backend nuance and the dead-result stub).
  The 12 `XFAIL` fixtures in the conformance suite are these honest refusals, curated and
  documented, never silent passes.

## Correctness harnesses (how the above is proven)

The gates live in the `justfile` and `tools/`; the strongest are render/exec differentials
on a real Metal GPU:

- `just strict-gate` -- spirv-val on every conformance fixture (~2.1k PASS / 12 XFAIL / 0
  FP-regression; the live count is in [STATUS.md](STATUS.md), the single source of truth).
- `just prove` / `prove-opt` / `prove-naga` / `prove-3oracle` -- render/exec diff vs
  independent references (glslang->SPIRV-Cross, naga) across fragment/vertex/compute.
- `just prove-integer` -- the FP-chaos-immune integer corpus (any DIFFER is a guaranteed
  bug); `just ub-check` machine-checks its UB-free contract; `just metamorphic` is the
  spirv-fuzz-style equivalent-program oracle.
- `just coverage-matrix` -- per-backend opcode/capability coverage (scope is bounded, not
  corpus-implicit). `just reduce` -- spirv-reduce a failing SPIR-V to a minimal repro.
- `tools/spv_input_validity_sweep.sh` (e54.4) -- the ARBITRARY-SPIR-V analog of the
  GLSL-source validity sweeps: feeds `.spv` binaries (not GLSL source, so it exercises
  consumption of external SPIR-V from glslang/DXC/spirv-opt) through all four backends and
  compile-checks each emission (glslang/naga/Metal/dxc), spirv-cross-discriminated. The
  GLSL-source sweeps only ever exercised zioshade's own frontend output; this one gates
  robust arbitrary-SPIR-V consumption. Runs in `just ci` and in the CI workflow (GLSL on
  Linux with the complete glslang oracle, WGSL via naga; each leg skips gracefully where
  its compiler is absent).
- Where those sweeps run in CI: GLSL + WGSL on Linux, MSL on a macOS runner (real Metal
  compiler), HLSL on a Windows runner (the Vulkan SDK's DXC). Those last two are
  COMPILE-validation only -- render/exec differentials need a GPU, which hosted runners
  do not have, so `just prove*` stays a local gate.

Always `PROVE_FULL=1 just prove` before claiming correctness (the default is a 1/25 sample).

## How to extend

- **Add a SPIR-V opcode to a backend**: add the `Op` member to `spirv.zig` (with its spec
  value, and an entry in the "opcode values match SPIR-V spec" test), then add a `case` to
  the backend's main `switch (inst.op)`. If the backend cannot lower it, `error.UnsupportedOp`
  (do not leave a stub). Add a regression test in the backend's `tests/*_tests.zig`.
- **Add a regression test for a miscompile**: prefer an oracle-free structural assertion
  (opcode/decoration count or an id-correlation check) in `tests/correctness_tests.zig` or
  `tests/optimizer_tests.zig`, so it runs without external tools. For render-class bugs, add
  a pair to `tests/integer_corpus/metamorphic/` (see its README for the equivalence laws).
- **Add an optimizer pass**: `fn(alloc, words) ![]const u32` in `compact_ids_passes.zig`,
  threaded into `generateInternal` at the right group. If it can invalidate the module, the
  `strict-gate` must stay green.
- **Diagnose a reported miscompile**: `bash tools/reduce.sh <failing.spv> <mode>` to minimize
  it, then read the reduced `.asm` and bisect with `generateNoOpt` vs `generate`.

## Conventions and invariants

- **Allocators are passed in, not global.** Every compilation/cross-compile entry point
  (`compileToSPIRV`, `spirvToHLSL/MSL/GLSL/WGSL`, ...) takes an `allocator` and the caller
  owns the returned bytes. Exceptions: the error-detail accessors (`lastErrorCtx`,
  `wgslLastErrorDetail`) return borrows into threadlocal storage the caller must NOT free;
  `reflectSPIRV` returns a `reflection.ShaderResources` freed via `.deinit(alloc)`, not
  `alloc.free` on bytes.
- **No process-wide init/finalize; safe to call concurrently.** Mutable compile state is
  threadlocal; `compat.zig` does hold one process-wide *atomic* seed counter (no lifecycle),
  which preserves the concurrent-safety guarantee.
- **Version shims via `compat`**, not version numbers: route `std.fs`/`std.process`/`std.Io`/
  allocator differences through `src/compat.zig`; the build floor is Zig 0.15.2, tested
  through 0.16 via capability detection.
- **House style**: no em dashes (use `--`); no AI attribution in commits/files; `const`
  over `var`; exhaustive switches; minimal, focused diffs. The CI `fmt` gate runs
  `zig fmt --check` on 0.15.2 -- do not commit 0.16-fmt reflow of files you did not logically
  change.
- **Public API surface** is `src/root.zig`, versioned with SemVer (pre-1.0: minor bumps may
  break). The internal `spirv_to_*` backend modules are private `const` imports (not
  exported); tools reach them through the public `spirvTo*` functions. root.zig also
  re-exports `diagnostic`, `reflection`, `spirv`, `cfg_structurize`, `compat`, and `semantic`
  as `pub const`, so those types are part of the public surface too.
