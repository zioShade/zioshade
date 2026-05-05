# Autoresearch Ideas — glslpp

## STATUS: 210/211 spirv-val, 0 mismatches, 0 failures  
## Current: 7308 total_bound across 211 shaders (session 11)
## We BEAT spirv-opt -O on ALL shaders (total: 7308 vs 7751 = -443 IDs, -5.7%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 11 CHANGES (-111 IDs total):
1. Scatter-store to CompositeConstruct (vectors): -24 IDs
2. Extended scatter-store to arrays: -8 IDs
3. Store-forward extract (single-index AC): -38 IDs
4. Trivial entry point elimination: -3 IDs
5. Dead store elimination for StorageBuffer: -25 IDs
6. CompositeExtract CSE (second pass): -2 IDs
7. VectorShuffle CSE: -2 IDs
8. Extract(ConstantComposite) folding: -9 IDs

## KEY INSIGHTS:
- Adding StorageBuffer (class 12) to redundantStoreElim: -25 IDs
  - Safety: reset tracking on barriers, atomics, function calls
- Second CSE pass at end of pipeline catches duplicates from storeForwardExtract
- Fixed critical cross-function CSE bug: block_sigs must be cleared on OpFunction
- CompositeExtract CSE deduplicates extract(same_composite, same_indices) within blocks
- foldSelect already handles constant-condition OpSelect (0 remaining)
- OpPhi is opcode 245 (NOT 253 which is OpReturn)
- Unary constant folding (FNegate/SNegate) is counterproductive: +1 ID (new constants at higher IDs)
- Extra DCE+retarget+merge round after second CSE: 0 IDs (pipeline already converges)

## EXHAUSTED OPTIMIZATIONS (all 0 IDs after last round):
- Type dedup, identity arithmetic, same-operand comparisons, copy propagation
- Multi-index store-forward extract, dead function-local vars, duplicate constants
- OpCopyObject elimination, extended block merging, strength reduction
- Trivial/same OpPhi, AC chains, cross-block AC CSE
- Second pipeline iteration, multi-store vars, redundant loads, dead decorations
- Unused interface variables, Extract(Shuffle) folding, identity VectorShuffle
- No-op conversion chains, duplicate arithmetic (with correct opcodes)
- Dead max-ID AccessChains, unused types, mergeable blocks, chained ACs
- Cross-block redundant loads for never-stored pointers
- Workgroup dead store elimination (stores removed but values still used)
- Constant-condition OpSelect: 0 instances (foldSelect handles)
- Unary constant folding: +1 ID (counterproductive)
- Third DCE+retarget+merge round: 0 IDs
- Dead constant-condition branches: 0 instances
- OpCompositeInsert: 0 instances in output

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Multi-block function inlining (~50 IDs)
2. SSA construction / value numbering
3. Codegen-level dead code elimination
4. Dead argument elimination for unused function parameters
5. Partial redundancy elimination (PRE) for cross-block AC hoisting

## INSTRUCTION DISTRIBUTION (top 10):
- Decorate: 1302, EntryPoint: 1171, TypeFunction: 846, Variable: 812
- Constant: 654, Load: 576, MemberDecorate: 501, ExecutionMode: 412
- Store: 381, Label: 377, AccessChain: 346, TypeVector: 336
- OpPhi: 12 (all non-trivial, different incoming values)
