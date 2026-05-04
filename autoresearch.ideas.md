# Autoresearch Ideas — glslpp

## STATUS: 211/211 spirv-val, 0 mismatches, 0 failures
## Current: 7387 total_bound across 211 shaders (session 11)
## We BEAT spirv-opt -O on ALL shaders (total: 7387 vs 7751 = -364 IDs, -4.7%)
## We BEAT glslang on ALL comparable shaders (-43%)

## SESSION 11 CHANGES:
- Scatter-store to CompositeConstruct optimization: -24 IDs (7419->7395)
  - New pass in compact_ids.zig: scatterStoreToComposite
  - Detects function-local vector vars with all-component AC stores + whole load
  - Replaces OpVariable + N*(OpAccessChain + OpStore) + OpLoad with OpCompositeConstruct
  - Key fix: AC indices are constant IDs, not literal values - needed const_vals map
- Extended scatter-store to arrays: -8 IDs (7395->7387)
  - Also handles OpTypeArray function-local variables
  - return-array.vert benefited most

## REMAINING OPTIMIZATION OPPORTUNITIES:

### 1. AC redundant load for readonly vars (0 IDs independently, but correct)
Extended elimRedundantLoads to handle AccessChain-derived pointers from readonly vars.
Correct but saves 0 because eliminated loads aren't at max ID position.

### 2. Store-forwarding through local structs (~5 IDs, MEDIUM effort)
Pattern: OpStore whole struct, then OpAccessChain + OpLoad individual members.
Could replace AC+load with OpCompositeExtract on the stored value.
copy.flatten.vert has this pattern (%23 = Light struct).

### 3. Multi-block function inlining (~50 IDs, VERY HIGH effort)
8 remaining function calls across 2 shaders with loops/switches.

### 4. Extended loop counter to OpPhi (~30 IDs, HIGH effort)
43 function-local vars with multi-store patterns.

### 5. Struct type scatter-store (needs member count analysis)
Struct function-local vars with all-member AC stores + whole load.
Would need OpTypeStruct member count tracking.
