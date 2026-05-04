# Autoresearch Ideas — glslpp

## STATUS: 211/211 spirv-val, 0 mismatches, 0 failures
## Current: 7456 total_bound across 211 shaders
## Previous: 198 shaders / 6827 bound

## SESSION 8 FIXES:
- constStoreForward: forward constant stores to func-local vars across blocks (-7 IDs)
- Fixed 'W' (OpSwitch) operand handling: post-increment not pre-increment
- Fixed entry-block CSE detection: include full entry block (not just up to first non-Label)
- Expanded test set from 198 to 211 shaders (13 more pass spirv-val)
- Regenerated ref_classification.txt (cache was accidentally deleted)

## EXHAUSTED APPROACHES (0 IDs saved):
- OpVectorShuffle CSE: 0 (all dups in different non-entry blocks)
- Extra pipeline iteration: 0
- Duplicate types/consts: 0 (compactIds handles)
- Extract(Construct) fold: 0 (already fully folded)

## REMAINING OPPORTUNITIES (HIGH EFFORT):
1. Multi-block function inlining (~50 IDs, VERY HIGH effort)
   - Only a few shaders affected
   - Requires: clone body, rewrite branch targets, handle merge/loop
   
2. SSA conversion for remaining loop variables (~30 IDs, HIGH effort)
   - 45 function-local vars remain, most are loop counters
   - Some loop counters already converted to OpPhi
   
3. Better codegen: emit fewer temporaries
   - Emit values directly instead of store+load patterns
   - Requires changes to semantic analysis and codegen layers

4. Cross-block CSE for non-entry blocks (~4 IDs, MEDIUM effort)
   - VectorShuffle dups in generate_height.comp
   - Requires dominance analysis between sibling blocks

## MEMORY LEAKS:
- constStoreForward leaks memory (small leak per shader)
- Need to fix ArrayList cleanup in error paths
