# Autoresearch Ideas — glslpp

## STATUS: 210/211 spirv-val, 0 mismatches, 0 failures  
## Current: 7319 total_bound across 211 shaders (session 11)
## We BEAT spirv-opt -O on ALL shaders (total: 7319 vs 7751 = -432 IDs, -5.6%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 11 CHANGES (-100 IDs total):
1. Scatter-store to CompositeConstruct (vectors): -24 IDs
2. Extended scatter-store to arrays: -8 IDs
3. Store-forward extract (single-index AC): -38 IDs
4. Trivial entry point elimination: -3 IDs
5. Dead store elimination for StorageBuffer: -25 IDs
6. CompositeExtract CSE (second pass): -2 IDs

## KEY INSIGHTS:
- Adding StorageBuffer (class 12) to redundantStoreElim: -25 IDs
  - Safety: reset tracking on barriers, atomics, function calls
- Second CSE pass at end of pipeline catches duplicates from storeForwardExtract
- Fixed critical cross-function CSE bug: block_sigs must be cleared on OpFunction
- CompositeExtract CSE deduplicates extract(same_composite, same_indices) within blocks
- foldSelect already handles constant-condition OpSelect (0 remaining)

## EXHAUSTED OPTIMIZATIONS (all 0 IDs after last round):
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
- Constant-condition OpSelect: 0 instances (foldSelect handles)

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Multi-block function inlining (~50 IDs)
2. SSA construction / value numbering
3. Codegen-level dead code elimination
