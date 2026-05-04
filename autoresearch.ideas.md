# Autoresearch Ideas — glslpp

## STATUS: 211/211 spirv-val, 0 mismatches, 0 failures
## Current: 7419 total_bound across 211 shaders (session 10)
## We BEAT spirv-opt -O on ALL shaders (total: 7419 vs 7751 = -332 IDs, -4.3%)
## We BEAT glslang on ALL comparable shaders (-42%)

## SESSION 10 CHANGES:
- Constant folding (binary ops on scalar constants): -7 IDs (7426->7419)
- Explored unary constant folding: +1 ID regression (reverted)
- Explored type dedup extension (OpTypeArray/OpTypePointer): 0 IDs (reverted)
- Explored extra DCE after retargetEmptyBlocks: 0 IDs (reverted)
- All easy wins exhausted. Pipeline fully converged.

## EXHAUSTED APPROACHES (0 IDs saved):
- Unary constant folding: +1 regression (creates new max IDs)
- Type dedup extension (Array/Pointer): 0 (dups not near bound)
- Dead function elimination: 0 (all functions are entry points)
- Identity VectorShuffle: 0 (already eliminated)
- Cross-block CSE: 0 (no duplicates across blocks)
- Extra DCE after retarget: 0 (pipeline converged)
- FMul(x, 0): 0, FMul(x, -1): 0
- Duplicate constants: 0 (already handled)
- Dead constants: 0 (DCE handles)
## We BEAT glslang on ALL shaders (total: ~6748 vs ~11662 where glslang succeeds = -42%)

## SESSION 10 FINDINGS:
- Dead function elimination: 0 dead functions in output (all are entry points)
- Identity VectorShuffle elimination: 0 remaining (already eliminated by DCE)
- Inverse conversion pairs: 0
- Dead blocks: 0
- FMul(x,0): 0
- OpLine: 0
- NoContraction: 0
- Pipeline fully converged: second round of passes saves 0 IDs
- Constant folding: 5 foldable ops but none save IDs (product constants don't exist)
- Cross-block SampledImage dups: 0
- Cross-block pure op dups: 0
- Store-then-load pairs: 0
- FAdd(x,x): 2 but no savings (same instruction count)
- Beat spirv-opt -O on ALL 211 shaders (total: 7426 vs 7751)
- Beat glslang on ALL comparable shaders
- 1 expected compile failure (line-directive.line.asm.frag - assembly directives)

## EXHAUSTED APPROACHES (0 IDs saved):
- Dead function elimination: 0 (all functions are entry points or called)
- Identity VectorShuffle: 0 (already eliminated by DCE/cascading)
- Cross-block CSE: 0 (no dominance relationships between sibling blocks)
- OpCopyObject elimination: 0 (none in benchmark set)
- Constant-store forwarding: already handled
- Inverse conversion pairs: 0
- Dead blocks: 0
- OpLine removal: 0 (none emitted)
- NoContraction removal: 0 (none emitted)
- Algebraic simplification: already comprehensive
- Type deduplication: compactIds handles

## CONCLUSION:
The SPIR-V binary optimization pipeline is FULLY OPTIMIZED at the current level.
We match or beat spirv-opt -O on every single shader. Further gains require:

1. **Codegen-level changes** (HIGH effort, potential ~100+ IDs)
   - Emit values directly instead of store+load patterns
   - Requires changes to semantic analysis and codegen layers

2. **Multi-block function inlining** (VERY HIGH effort, potential ~50 IDs)
   - 8 remaining function calls in 2 shaders
   - Functions have loops/switches (multi-block control flow)

3. **SSA conversion for remaining loop variables** (HIGH effort, ~30 IDs)
   - 43 function-local vars remain, all multi-store
   - Many are loop counters with store-load patterns
