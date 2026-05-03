# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Current: 7061 total_bound across 199 shaders (-0.96% from 7156, -8.8% from 7742, -27.4% from 9721, -35.1% from 10881)
## We now BEAT glslang by 5290 IDs total! (12351 vs 7061, -42.8%)
## 193 shaders strictly better, 6 equal, 0 worse

## SESSION 5 FINAL STATUS: 7061 total_bound (-95 from session start 7156)
## Exhaustive search confirms: no further easy wins exist.
## Tried and failed:
##   - OpTypeArray dedup: saves 0 (compactIds already handles)
##   - OpCopyObject elim: saves 4 IDs but on non-benchmark shaders
##   - Double pipeline iteration: causes timeouts
##   - Second round of cheap passes: 0 IDs (fully converged)
##   - Constant branches: 0 found
##   - Same-target branches: 0 found
##   - Duplicate OpConstant: 0 found
##   - Duplicate OpTypeFunction: 0 found
##   - Duplicate OpCompositeConstruct: 0 found
##   - Composite reconstruction pattern: 0 found
##   - Store-to-load forwarding: 0 found
## Next significant gains require SSA conversion or multi-block inlining.
1. AccessChain CSE within basic blocks: -3 IDs
   - Per-block dedup with entry-block cross-block support
   - Fixed dominance violation (per-function → per-block scope)
2. Fix elimRedundantLoads storage class values: -13 IDs
   - Was checking 1,2,5 (Input, Uniform, CrossWorkgroup) instead of 0,1,2 (UniformConstant, Input, Uniform)
   - UniformConstant (0) is the most common read-only class for sampler/texture variables
3. OpSampledImage CSE within blocks: -10 IDs
   - Extended cseWithinBlocks to handle OpSampledImage (same type+image+sampler)
   - Also handles AccessChain via same unified pass

## EXHAUSTED EASY WINS:
- No duplicate VectorShuffle within blocks (checked)
- No duplicate CompositeConstruct within blocks (checked)
- No remaining easy peephole patterns
- All type dedup already handled
- All trivial function inlining done
- Dead code/loop/store elimination done
- Algebraic simplification done
- Redundant load elimination done (now with correct storage classes)

## REMAINING MINOR OPPORTUNITIES:

### OpCopyObject elimination (saves 4 IDs on non-benchmark shaders)
transpose.legacy.vert has 4 OpCopyObject. Works but excluded from benchmark.

### SSA conversion for loop variables (saves ~100+ IDs, HIGH effort)
Loop counters are emitted as function-local variables with load/store.
Converting to OpPhi-based SSA would eliminate the variable, loads, and stores.
Pattern: OpStore %var %init; loop { OpLoad %var; ... OpStore %var %new_val }
→ OpPhi %initial %entry_block %new_val %continue_block
Requires: detect loop structure, replace var refs with OpPhi results.

### Multi-block function inlining (saves ~200+ IDs, VERY HIGH effort)
Only a few shaders affected. Requires: clone body, rewrite branch targets,
handle OpSelectionMerge/OpLoopMerge, fix up structured control flow.
