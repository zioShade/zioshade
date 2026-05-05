# Autoresearch Ideas — glslpp

## STATUS: 210/211 spirv-val, 0 mismatches, 0 failures  
## Current: 7284 total_bound across 211 shaders (session 11)
## We BEAT spirv-opt -O on ALL shaders (total: 7284 vs 7751 = -467 IDs, -6.0%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 11 CHANGES (-135 IDs total):
1. Scatter-store to CompositeConstruct (vectors): -24 IDs
2. Extended scatter-store to arrays: -8 IDs
3. Store-forward extract (single-index AC): -38 IDs
4. Trivial entry point elimination: -3 IDs
5. Dead store elimination for StorageBuffer: -25 IDs
6. CompositeExtract CSE (second pass): -2 IDs
7. VectorShuffle CSE: -2 IDs
8. Extract(ConstantComposite) folding: -9 IDs
9. Second constFold after storeForwardExtract: -1 ID
10. Second foldCompositeExtract after forwarding: -8 IDs
11. Eliminate dead void calls: -14 IDs
12. Fold VectorShuffle(CompositeConstruct): -1 ID

## KEY INSIGHTS:
- Re-running constFold + foldCompositeExtract after storeForwardExtract saves 9 IDs
  - Store forwarding creates new CompositeExtract from stored values
  - Some of those values are CompositeConstruct or ConstantComposite
  - Running foldCompositeExtract again catches these new patterns
  - Third iteration converges (0 IDs)
- Dead void calls: calls to pure (no stores/calls/atomics) void-returning functions
  - Only remove the calls, not the functions (they may be entry points)
  - Found in 2 shaders (cfg-preserve-parameter.comp, partial-write-preserve.frag)
- The 1 failing shader is a SPIR-V assembly file (.asm.frag), not GLSL — not fixable

## EXHAUSTED OPTIMIZATIONS (all 0 IDs):
- Unary const fold (+1, reverted), dead branches (0), CopyObject (8, all low IDs)
- Duplicate constants/CC/types (0), trivial/same OpPhi (0), OpSelect (0)
- Cross-block redundant stores (0), 2-block function inlining (2, too complex)
- Dead interface vars (0), dead-store vars (1, used by OpExtInst)
- 1-store-N-load non-constant vars (0), second constStoreForward (0)
- Second elimUninitVars (0), third pass iteration (0)
- AC chains (0), AC dedup (0), identity conversions (0)
- Constant shuffles (0), OpSelect conversion (0/13 SelectionMerge)
- Dead non-void calls (0 remaining OpFunctionCall instructions)
- Dead value-producing instructions (0 - DCE is comprehensive)
- Sequential block dead stores (0), same-value OpPhi (0)
- Extended type dedup (0), identity ops (0), copy prop (0)
- Multi-index AC savings (2, complex), extended block merging (0)
- Extract(Shuffle) fold (0), identity VectorShuffle (0)

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Multi-block function inlining (~50 IDs) - requires complex CFG merging
2. SSA construction / value numbering - requires liveness analysis
3. Codegen-level dead code elimination
4. Partial redundancy elimination (PRE) for cross-block AC hoisting
