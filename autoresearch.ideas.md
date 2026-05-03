# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Current: 7087 total_bound across 199 shaders (-0.96% from 7156, -8.4% from 7742, -27.1% from 9721, -34.9% from 10881)
## We now BEAT spirv-opt by 5950 IDs total! (13037 vs 7087)

## SESSION 4 ACHIEVEMENTS (7156 → 7087, -69 IDs, -0.96%):
1. Single-block function inlining with OpVariable: -35 IDs
   - Separated has_var from has_call_or_cf in inlineTrivialFuncs
   - Added moveVarToEntry pass to fix SPIR-V variable ordering
2. Redundant load elimination for read-only vars: -13 IDs
   - CSE loads of Input/UniformConstant/Uniform storage class vars
3. CompositeExtract from CompositeConstruct folding: -15 IDs
   - Pattern: extract(construct(a,b,...), N) = Nth component
4. Uninit var elimination (loaded but never stored): -4 IDs
   - Fixed: OpUndef (opcode 1) was missing from getOpInfo table
   - Fixed: Added OpExtInst/OpFunctionCall handling to avoid false positives
5. DCE after elimUninitVars: -2 IDs (dead pointer types)

## REMAINING GAPS vs spirv-opt (only 4 shaders):
- partial-write-preserve.frag: +77 (multi-block function inlining)
- image-query.desktop.frag: +60 (multi-block function inlining)
- image-formats.desktop.noeliminate.comp: +43
- cfg-preserve-parameter.comp: +38

## REMAINING MINOR OPPORTUNITIES:

### Duplicate OpSampledImage elimination (saves 3 IDs)
separate-sampler-texture-array.vk.frag (1), separate-sampler-texture.vk.frag (2).
Simple CSE: same (image, sampler) pair → reuse first OpSampledImage result.

### Multi-block function inlining (saves ~218 IDs, VERY HIGH effort)
Only 4 shaders affected. Requires: clone body, rewrite branch targets,
handle OpSelectionMerge/OpLoopMerge, fix up structured control flow.
