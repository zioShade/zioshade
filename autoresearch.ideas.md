# Autoresearch Ideas — glslpp

## STATUS: 198/198 spirv-val, 0 mismatches, 0 failures
## Current: 6839 total_bound across 198 shaders
## Beat glslang by 5387 IDs (44% better)
## Beat spirv-opt -O by 293 IDs
## 0 shaders where we use more IDs/instructions than glslang

## SESSION 7 FIXES:
- Fixed elimUnreachableCalls: entry point protection + OpFunctionEnd + OpName cleanup
- Fixed DCE dead var elim: also remove AccessChain+Store for dead vars
- Fixed stale zig cache issue (was caching old binaries)
- Retarget empty passthrough blocks: -29 IDs

## EXHAUSTED APPROACHES (0 IDs saved):
- Extra DCE pass after final compact: 0 (fully converged)
- Duplicate constants: 0 (compactIds handles)
- Duplicate types: 0 (compactIds handles)
- Dead loads (apparent): FALSE POSITIVES from incomplete opcode table
- Extra pipeline iteration: 0

## REMAINING OPPORTUNITIES (HIGH EFFORT):
1. Multi-block function inlining (~50 IDs, VERY HIGH effort)
   - Only a few shaders affected
   - Requires: clone body, rewrite branch targets, handle merge/loop
   
2. SSA conversion for remaining loop variables (~30 IDs, HIGH effort)
   - 47 function-local vars remain, most are loop counters
   - Some loop counters already converted to OpPhi
   
3. Better codegen: emit fewer temporaries
   - Emit values directly instead of store+load patterns
   - Requires changes to semantic analysis and codegen layers
