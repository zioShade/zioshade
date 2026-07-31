# Architecture

A contributor's map to the codebase. For scope/limitations see
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md); for conformance counts see
[STATUS.md](STATUS.md); for the correctness methodology see
[DIFFERENTIAL_PROOF.md](DIFFERENTIAL_PROOF.md) and [COVERAGE_MATRIX.md](COVERAGE_MATRIX.md).
This doc is about *how the code is laid out and how to navigate it*.

zioshade is two compilers sharing one IR:

```
GLSL source
  -> preprocess -> lex -> parse (AST) -> semantic (IR) -> codegen (SPIR-V) -> optimize
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
| `compact_ids.zig` | ID compaction (renumber after passes mutate the module) |
| `loop_counter_phi.zig`, `inline_multiblock.zig`, `fold_extract_construct.zig` | Specialized passes |
| `cfg_structurize.zig` | Pre-pass run by every backend: recovers missing `OpSelectionMerge` for reducible unstructured `if`/`switch` |
| `spirv_to_hlsl.zig` / `_msl.zig` / `_glsl.zig` / `_wgsl.zig` | The four cross-compiler backends |
| `spirv_cross_common.zig` | Shared backend helpers (opcode `getOpInfo`, emit BinOp/Call, decoration tables) |
| `spirv.zig` | The SPIR-V enums: `Op`, `Capability`, `BuiltIn`, `StorageClass`, `Decoration`, `ExecutionMode`, `GLSLstd450` |
| `reflection.zig` | Enumerate UBO/SSBO/sampler/IO resources + JSON from a SPIR-V module |
| `kernel_fusion.zig` | Merge compute shaders / link SPIR-V modules |
| `root.zig` | The public API (`compileToSPIRV`, `spirvToHLSL/MSL/GLSL/WGSL`, `reflectSPIRV`, ...) |
| `cli.zig` | The `zioshade` command-line tool |
| `c_abi.zig` | The C ABI (`include/zioshade.h`, `zig build c-lib`) |
| `wasm.zig` | The WebAssembly target |
| `compat.zig` + `build_compat.zig` | Zig 0.15.2 <-> 0.16 version shims (capability-detected, never version-number-gated) |

The backends are the four biggest files (~34k LOC together); they are independent emitters
that each walk the SPIR-V module instruction-by-instruction and emit target source.

## The GLSL -> SPIR-V frontend

`compileToSPIRV` (root.zig) drives: `preprocessor` -> `lexer` -> `parser` -> `semantic`
(builds an `ir.Module`) -> `codegen.generate` (SPIR-V bytes, optimized) or
`codegen.generateNoOpt` (faithful, unoptimized). `generateNoOpt` exists so a caller can
prove correctness on the *unoptimized* IR -- some miscompiles only surface on one path
(the `#loop-continue-deadincr` class was invisible on optimized SPIR-V; `prove_naga`
exercised it on the unoptimized path).

The `Op` enum in `spirv.zig` is the set of SPIR-V opcodes zioshade models (251 today; see
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
10. **Final cleanup**: `elimDeadVarStores`, DCE, `retargetEmptyBlocks`, CSE, DCE, `elimIdentityStores`, DCE. (`copyMemoryOpt` is **disabled** -- it produced undefined IDs after DCE; see the comment in `generateInternal`.)
11. **Import/global cleanup**: `elimUnusedImports`, DCE, compactIds, `elimUnusedGlobals`, DCE, `stripDeadDebugInfo`, DCE, compactIds.
12. **Final type dedup**: `dedupArrayTypes`, `dedupStructTypes`, `dedupPointerTypes`, `dedupFunctionTypes`, DCE, `ensureLoopPreheader` (a function whose entry block is a loop header gets a pre-header so it is never a branch target), `compactIds`.

Every pass is `fn(alloc, words) ![]const u32` -- pure transform of the SPIR-V word stream;
on allocation failure it returns the input unchanged (the "never miscompile, degrade
gracefully" rule). Passes that can leave a module invalid if buggy are gated by `hasMalformedCFG`
and the conformance `strict-gate` (spirv-val on every fixture, 0 FP-regression).

## The cross-compiler backends (SPIR-V -> HLSL / MSL / GLSL / WGSL)

Each backend entry (`spirvToHLSL` etc.) first runs `cfg_structurize` -- a module-level
pre-pass that recovers missing `OpSelectionMerge` for **reducible** unstructured `if`/`switch`
(no-op on already-structured input, which is everything zioshade's own frontend emits). It
makes externally-optimized or hand-authored SPIR-V with stripped merges compile faithfully.
Unstructured **loops** (missing `OpLoopMerge`) and irreducible CFGs **fail loud**
(`error.UnstructuredControlFlow`) rather than miscompile.

Then the backend walks the module and dispatches per instruction (`switch (inst.op)` in the
main emit function), emitting target source. Shared logic lives in `spirv_cross_common.zig`
(opcode operand info, `emitBinOp`/`emitCall`, decoration handling). An opcode a backend
cannot faithfully lower hits `error.UnsupportedOp` (a named honest-error) -- the catch-all
fails loud, so no opcode silently falls through to placeholder output.

## The honest-error contract, and where it is enforced

The one rule (see [AGENTS.md](../AGENTS.md)): **never emit plausible-but-wrong output.** It
is enforced at three layers:

- **Frontend**: untranslatable GLSL -> `error.CodegenFailed` / `error.SemanticFailed` (and
  `hasMalformedCFG` rejects dangling control flow before it can ship).
- **Optimizer**: each pass degrades to "return input unchanged" on any allocation failure;
  `strict-gate` (spirv-val) is the regression backstop.
- **Backends**: per-opcode `error.UnsupportedOp`; the dispatch catch-all fails loud. The
  13 `XFAIL` fixtures in the conformance suite are these honest refusals, curated and
  documented, never silent passes.

## Correctness harnesses (how the above is proven)

The gates live in the `justfile` and `tools/`; the strongest are render/exec differentials
on a real Metal GPU:

- `just strict-gate` -- spirv-val on every conformance fixture (PASS 2108 / 0 FP-regression).
- `just prove` / `prove-opt` / `prove-naga` / `prove-3oracle` -- render/exec diff vs
  independent references (glslang->SPIRV-Cross, naga) across fragment/vertex/compute.
- `just prove-integer` -- the FP-chaos-immune integer corpus (any DIFFER is a guaranteed
  bug); `just ub-check` machine-checks its UB-free contract; `just metamorphic` is the
  spirv-fuzz-style equivalent-program oracle.
- `just coverage-matrix` -- per-backend opcode/capability coverage (scope is bounded, not
  corpus-implicit). `just reduce` -- spirv-reduce a failing SPIR-V to a minimal repro.

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

- **Allocators are passed in, never global.** Every public function takes an `allocator`;
  callers own and free the returned bytes (`defer alloc.free(...)`).
- **Threadlocal-only mutable state.** Safe to call from multiple threads; no process-wide
  init/finalize.
- **Version shims via `compat`**, not version numbers: route `std.fs`/`std.process`/`std.Io`/
  allocator differences through `src/compat.zig`; the build floor is Zig 0.15.2, tested
  through 0.16 via capability detection.
- **House style**: no em dashes (use `--`); no AI attribution in commits/files; `const`
  over `var`; exhaustive switches; minimal, focused diffs. The CI `fmt` gate runs
  `zig fmt --check` on 0.15.2 -- do not commit 0.16-fmt reflow of files you did not logically
  change.
- **Public API surface** is `src/root.zig`, versioned with SemVer (pre-1.0: minor bumps may
  break). The internal `spirv_to_*` modules are not exported; tools reach the backends
  through the public `spirvTo*` functions.
