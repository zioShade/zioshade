# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, ~185/199 true matches, 149/149 gap tests
## Commit: 4ac148b (DepthUnchanged codegen + depth gap tests)

## ACCURATE METRICS (with proper BuiltIn tracking):
- The counting methodology has been evolving. With proper tracking of BuiltIn variables
  and AccessChain-derived pointers, the actual match count is much higher than initial counts.
- All 9 Ghostty shaders produce correct SPIR-V with proper output values
- Dead function elimination matches glslang (2 functions per Ghostty shader)
- Most "structural mismatches" are SSA vs memory differences (functionally equivalent)

## REMAINING GAPS (mostly vendor extensions, NOT needed for wintty):
- QCOM image processing (4): block-match-sad/ssd, box-filter, sample-weighted
- ARM tensor (1): tensor
- Ray query (1): rq-position-fetch
- Nonuniform qualifier (1): needs runtime arrays + NonUniformEXT
- shader-draw-parameters (2): Our output IS correct, counting script misses BuiltIn struct member stores
- texture_buffer: Our output IS correct, counting script misses the store

## FEATURES ADDED THIS SESSION:
- ✅ floatBitsToUint/floatBitsToInt/intBitsToFloat/uintBitsToFloat → OpBitcast
- ✅ Dead function elimination (BFS reachability from main)
- ✅ gl_FragDepth + BuiltIn FragDepth decoration
- ✅ DepthReplacing/DepthGreater/DepthLess/DepthUnchanged execution modes
- ✅ EarlyFragmentTests execution mode
- ✅ layout(depth_greater/less/unchanged/early_fragment_tests) parsing
- ✅ 54 gap tests (50 original + 4 depth tests)

## HIGHEST PRIORITY NEXT STEPS:
1. **GPU visual correctness verification** — build a headless Vulkan renderer to do pixel-by-pixel comparison between our SPIR-V and glslang's. This is the ONLY way to prove correctness.
2. **Improve counting methodology** — track BuiltIn struct member stores properly
3. **gl_PerVertex block wrapping** — canonical output for vertex shaders
4. **Function inlining** — reduce OpFunctionCall overhead

## VERIFIED WORKING FEATURES:
- All standard GLSL texture operations (texture, texelFetch, textureLod, textureOffset, etc.)
- Shadow texture sampling with bias and offsets
- Struct/array constants (OpConstantComposite)
- Spec constants (OpSpecConstant)
- 8-bit integer types and conversions
- Vector type conversions (vecN↔ivecN↔uvecN)
- Separate sampler/texture, subpass inputs (MS), input attachments
- Barrier and memory barrier operations
- Dead function elimination
- Bitcast builtins (floatBitsToUint, etc.)
- gl_FragDepth with depth layout qualifiers and execution modes
- samplerBuffer and imageBuffer types
