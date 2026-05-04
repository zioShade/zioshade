# Autoresearch Ideas — glslpp

## STATUS: 210/211 spirv-val, 0 mismatches, 0 failures  
## Current: 7349 total_bound across 211 shaders (session 11)
## We BEAT spirv-opt -O on ALL shaders (total: 7349 vs 7751 = -402 IDs, -5.2%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 11 CHANGES (-70 IDs total):
1. Scatter-store to CompositeConstruct (vectors): -24 IDs
   - New pass scatterStoreToComposite in compact_ids.zig
   - Pattern: function-local vector var, all components stored via AC, whole var loaded once
   - Replaces with OpCompositeConstruct, eliminating var + ACs + stores
2. Extended scatter-store to arrays: -8 IDs
   - Also handles OpTypeArray with same pattern
3. Store-forward extract (single-index AC): -38 IDs
   - New pass storeForwardExtract in compact_ids.zig
   - Pattern: function-local var stored once, read only via single-index AC + Load
   - Replaces AC+Load with OpCompositeExtract, eliminating var + store + ACs
   - Fixed: multi-index AC chains restricted (wc==5 only) to avoid type mismatches
4. AC redundant load extension: 0 IDs (correct, included for completeness)

## EXHAUSTED OPTIMIZATIONS (0 IDs each):
- Type dedup (all types): 298 duplicates, all at low IDs, 0 savings on bound
- Identity arithmetic (x+0, x*1): 0 instances
- Same-operand comparisons: 0 instances
- Copy propagation for non-constant stores: 0 candidates
- Multi-index store-forward extract: only 2 IDs potential
- Dead function-local vars: 9 truly dead (all at low IDs, 0 bound savings)
- Duplicate constants: 0 instances (compactIds handles)
- OpCopyObject elimination: 0 savings on benchmark set
- Second pipeline iteration: fully converged
- All CSE extensions (VectorShuffle, more pure ops): 0 savings
- Cross-block AC CSE: duplicates in sibling blocks, not chains

## NEXT OPTIMIZATION TARGETS (all HIGH effort):

### 1. Multi-block function inlining (~50 IDs, VERY HIGH effort)
8 remaining function calls in 2 shaders with loops/switches.

### 2. Extended loop counter to OpPhi (~30 IDs, HIGH effort)
43 function-local vars with multi-store patterns.
Need dominance analysis and SSA construction.

### 3. Multi-index store-forward extract (~2 IDs, LOW effort but LOW reward)
Need nested OpCompositeExtract for multi-index AC chains.
Requires intermediate type resolution.

## ARCHITECTURAL INSIGHT:
The bound is dominated by function-level instructions (loads, stores, arithmetic, labels).
Type/constant dedup doesn't help because types get low IDs.
To reduce bound, must eliminate high-ID instructions (the last instructions in functions).
The last instructions are usually OpReturn, OpStore, OpFAdd — essential operations.
Only complex control flow transforms (inlining, SSA) can meaningfully reduce these.
