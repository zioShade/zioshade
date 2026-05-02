# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Current: 7753 total_bound across 199 shaders (-20.2% from 9721, -28.8% from 10881)
## 5 IDs BETTER than spirv-opt --compact-ids + all aggressive passes!

## THIS SESSION OPTIMIZATIONS:
30. Comparison operator dedup via pure_op_cache (-2 IDs)
31. Constant folding in type constructor: int/uint/float literal → target type (-21 IDs)
32. AccessChain merging: chained ACs with single-use intermediates → single multi-index AC (-98 IDs)
33. Global load cache for Input/Uniform from all blocks (-1 ID)

## OPTIMIZATION PIPELINE:
1. Semantic analysis → IR instructions (with caching + dedup)
2. Codegen → SPIR-V binary
3. mergeAccessChains (new!) → merge chained AccessChains
4. deadCodeElim → iterative DCE to fixpoint
5. compactIds → eliminate ID gaps

## REMAINING WASTE: 199 IDs (1 per shader, from pre-allocation — minimum achievable)

## FUTURE OPTIMIZATION OPPORTUNITIES:

### Cross-block load caching with dominance (~30 IDs)
30 global cross-block load duplicates remain. Can't cache from non-dominating blocks.
Would need: emit loads in entry block proactively for frequently-accessed global variables.

### AccessChain merge with multi-use bases (~20 IDs)
20 chained ACs have intermediate results used by multiple instructions.
Would need: duplicate the merged indices for each use, or keep intermediates.

### bvec→int roundtrip optimization (~3 IDs in casts.comp)
`ivec4(bvec4(x))` currently: extract → INotEqual → construct bvec → extract → Select.
Should simplify to: x != 0 ? 1 : 0 per component.

### Compile time optimization
DCE + compaction + merge adds overhead. Could profile and optimize.

## THINGS THAT DIDN'T WORK:
- AccessChain merge with reversed index order (spirv-val failures)
- Global AccessChain cache from all blocks (dominance violations)
- Binary op constant folding (all conversions are runtime values)
- emitPureOp for mix/select/ext_inst/composite_construct (0 IDs, DCE handles)
