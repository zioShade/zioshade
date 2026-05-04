# Autoresearch Ideas — glslpp

## STATUS: 211/211 spirv-val, 0 mismatches, 0 failures
## Current: 7452 total_bound across 211 shaders

## SESSION 9 CHANGES:
- Extended store forwarding to non-constant 1-store-1-load vars (-4 IDs)
- Fixed memory leak in constStoreForward
- Analyzed remaining 43 function-local vars — all multi-store or AC-used

## EXHAUSTED APPROACHES (0 IDs saved):
- OpVectorShuffle CSE: 0 (all dups in different non-entry blocks)
- Duplicate types: 0 (compactIds handles)
- Extract(Construct) fold: 0 (already fully folded)
- Dead OpUndef: 0 (all used, DCE handles)
- Redundant stores: 0 (all eliminated)
- Duplicate types: 0 (compactIds handles)

## REMAINING OPPORTUNITIES (HIGH EFFORT):
1. Multi-block function inlining (~50 IDs, VERY HIGH effort)
   - 8 remaining function calls in 2 shaders
   - Functions have loops/switches (multi-block control flow)
   
2. SSA conversion for remaining loop variables (~30 IDs, HIGH effort)
   - 43 function-local vars remain, all multi-store
   - Many are loop counters with store-load patterns
   
3. Better codegen: emit fewer temporaries
   - Emit values directly instead of store+load patterns
   - Requires changes to semantic analysis and codegen layers

4. Cross-block CSE for non-entry blocks (~4 IDs, MEDIUM effort)
   - VectorShuffle dups in generate_height.comp
   - Requires dominance analysis between sibling blocks

## ANALYSIS NOTES:
- 0 same-block 1-store-1-load vars remaining
- 0 entry-store-only multi-load vars remaining
- 0 dead decorations (OpDecorate on undefined IDs) affect bound
- Top shaders by bound: ocean.vert(183), ground.vert(163), generate_height.comp(111)
- Remaining 43 func-local vars: all require complex analysis
