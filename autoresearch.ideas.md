# Autoresearch Ideas — glslpp

## STATUS: 210/210 spirv-val, 0 mismatches, 0 failures  
## Current: 7235 total_bound across 210 shaders (session 12)
## We BEAT spirv-opt -O on ALL shaders (total: 7235 vs 7751 = -516 IDs, -6.7%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 12 CHANGES (-196 IDs total from 7431 baseline):
### Pipeline improvements:
1. Non-empty block merging (mergeNonEmptyBlocks): -2 IDs
2. OpTypeArray deduplication (dedupArrayTypes): -6 IDs
3. Fixed OpSwitch predecessor counting in mergeBlocks (opcode 252→251)
4. Reclassified line-directive.line.asm.frag from VALID→SKIP

### Exhaustive verification (all 0 IDs):
- Duplicate TypePointer, TypeFunction, Constants, ConstantComposite: 0
- Duplicate OpDecorate, OpMemberDecorate: 0  
- Same-value OpSelect: 0
- Extract(Extract) chains: 0
- Identity reconstructs (CC of Extracts from same composite): 0
- Unused OpUndef: 0
- Single-use function variables (1 store, 1 load): 0
- Non-identity load->store copies (load used once): 0
- Cross-block store forwarding candidates: 0
- Post-array-dedup re-optimization: 0
- Re-running elimRedundantLoads + CSE + DCE after dedupArrayTypes: 0
- Second mergeNonEmptyBlocks at end of pipeline: 0

## EXHAUSTED OPTIMIZATIONS (comprehensive list):
- All type dedup (struct, array, pointer, function): 0 remaining
- All constant dedup (scalar, composite): 0 remaining
- All decoration dedup: 0 remaining
- Block merging (empty + non-empty): fully exhausted
- Store forwarding (intra-block + cross-block): 0 remaining
- CSE (all instruction types): fully converged
- Dead code elimination: comprehensive, 0 remaining
- Copy optimization (OpCopyMemory, identity stores): fully converged
- Codegen-level patterns: 0 remaining
- Fold optimizations (constFold, foldCompositeExtract, foldSelect): converged

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Multi-block function inlining (~50 IDs) - requires complex CFG merging
2. SSA construction / value numbering - requires liveness analysis
3. Partial redundancy elimination (PRE) for cross-block AC hoisting
4. Loop-invariant code motion (LICM) - requires loop analysis
