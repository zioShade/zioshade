# Autoresearch Ideas — glslpp

## STATUS: 210/211 spirv-val, 0 mismatches, 0 failures  
## Current: 7321 total_bound across 211 shaders (session 11)
## We BEAT spirv-opt -O on ALL shaders (total: 7321 vs 7751 = -430 IDs, -5.5%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 11 CHANGES (-98 IDs total):
1. Scatter-store to CompositeConstruct (vectors): -24 IDs
2. Extended scatter-store to arrays: -8 IDs
3. Store-forward extract (single-index AC): -38 IDs
4. Trivial entry point elimination: -3 IDs
5. Dead store elimination for StorageBuffer: -25 IDs
6. Extract(Shuffle) fold: 0 IDs (correct, no instances)
7. Identity VectorShuffle elimination: 0 IDs (correct, all are swizzles)

## KEY INSIGHT: Adding StorageBuffer (class 12) to redundantStoreElim
- Only safe when: no barriers, atomics, or function calls between stores
- Also added safety resets for OpFunctionCall, OpCopyMemory, OpControlBarrier, OpMemoryBarrier, and all atomic ops (207-230)
- Main savings: rmw-opt.comp (-15), defer-parens.comp (-10)

## EXHAUSTED OPTIMIZATIONS (all 0 IDs):
- Type dedup, identity arithmetic, same-operand comparisons, copy propagation
- Multi-index store-forward extract, dead function-local vars, duplicate constants
- OpCopyObject elimination, extended block merging, strength reduction
- Trivial/same-value OpPhi, AC chains, cross-block AC CSE
- Second pipeline iteration, multi-store vars, redundant loads, dead decorations
- Unused interface variables, Extract(Shuffle) folding, identity VectorShuffle
- No-op conversion chains, duplicate arithmetic (with correct opcodes)
- Dead max-ID AccessChains, unused types, mergeable blocks, chained ACs
- Cross-block redundant loads for never-stored pointers
- Workgroup dead store elimination (stores removed but values still used)

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Multi-block function inlining (~50 IDs)
2. SSA construction / value numbering
3. Codegen-level dead code elimination
