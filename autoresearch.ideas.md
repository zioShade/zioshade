# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Current: 7852 total_bound across 199 shaders (-19.2% from 9721, -27.8% from 10881)
## 25 IDs BETTER than spirv-opt --compact-ids + all aggressive passes!

## THIS SESSION OPTIMIZATIONS:
30. Comparison operator dedup via pure_op_cache (-2 IDs)
31. Constant folding in type constructor: int/uint/float literal → target type constant (-21 IDs)
    - When vec4(0, 2, 3, 4) with int literals in float constructor, fold directly to float constants
    - Eliminates OpConvertSToF instructions for constant operands
    - Added tryFoldConversion helper for IR-level constant folding
32. Binary op constant folding: no additional savings (conversions are runtime values)
33. emitPureOp for OpSelect, OpExtInst, OpCompositeConstruct: correct but 0 savings (pre-allocated IDs already compacted by DCE)

## REMAINING CROSS-BLOCK DUPLICATES:
- OpLoad: 47 (21 for Input/Uniform/PushConstant, rest for Output/StorageBuffer)
- OpAccessChain: 11 (could merge chained AccessChains)
- OpFunction: 35 (can't optimize)
- Pure ops: ~10 (OpBitwiseAnd, OpSNegate, etc.)

## REMAINING SHADERS WHERE WE USE MORE IDs THAN GLSLANG:
- push-constant-as-ubo.push-ubo.vk.frag: +1 (likely 1 extra AccessChain)
- spec-constant-block-size.vk.frag: +1 (likely 1 extra AccessChain)
- ubo_layout.frag: +2 (chained AccessChains vs single multi-index)
- casts.comp: +3 (bvec→ivec roundtrip not optimized)

## FUTURE OPTIMIZATION OPPORTUNITIES:

### Multi-index AccessChain merging (-11+ IDs)
When emitting AccessChain where base is itself an AccessChain result, merge indices.
FAILED on first attempt: caused 40 spirv-val failures.
Root cause: the intermediate AccessChain instructions become orphaned, and the cache entries
reference stale base IDs. Need to handle cache invalidation properly.
**Safer approach**: Merge in codegen or in DCE post-processing pass.
**Expected savings**: ~11 IDs from AccessChain merging + potentially more from reduced type instructions.

### Cross-block load caching for Input/Uniform (~21 IDs)
21 cross-block load duplicates for Input/Uniform/PushConstant variables.
Can't simply cache from all blocks due to SPIR-V dominance rules.
**Approach**: Emit speculative loads in entry block for frequently-used Input/Uniform variables.
Requires multi-pass analysis: first scan to find which vars are loaded, then emit loads.

### bvec→int roundtrip optimization (-3 IDs in casts.comp)
`ivec4(bvec4(x))` currently extracts each component, does INotEqual, constructs bvec4,
then extracts again and uses Select. Should be simplified to `x != 0 ? 1 : 0` directly.

### Compile time optimization
DCE + compaction adds overhead. Could profile and optimize the post-processing passes.

## THINGS THAT DIDN'T WORK THIS SESSION:
- AccessChain merging at semantic level (40 failures, cache corruption)
- Binary op constant folding (all conversions are runtime values, not constants)
- emitPureOp for mix/select/ext_inst/composite_construct (0 IDs, DCE already handles)
