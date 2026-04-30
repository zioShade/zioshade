# Autoresearch Ideas

## CURRENT STATUS: 199/199 spirv-val, 9/199 real output mismatches, 9/10 Ghostty shaders (common.glsl is header-only)

## GOAL: Replace glslang C++ pipeline in deblasis/wintty with pure Zig implementation

## REMAINING 9 MISMATCHES (all vendor extensions or complex features):
- QCOM image processing (4): block-match-sad, block-match-ssd, box-filter, sample-weighted
- ARM tensors (3): tensor, tensor_params, tensor_read
- nonuniform-qualifier (1/14 stores): needs nonuniformEXT, runtime arrays, image atomics
- ray-query (1): needs ray tracing support

## DONE (all sessions, key items):
- ✅ 199/199 spirv-val conformance
- ✅ 9/10 Ghostty shaders (cell_text.f.glsl fixed via SSA materialization)
- ✅ SPIR-V output ~0.73x glslang size
- ✅ Separate sampler/texture, input attachments, spec constants, 8-bit arithmetic
- ✅ std140/std430 layout, proper decorations
- ✅ SSA optimization, constant dedup, two-buffer codegen

## TRIED & ABANDONED:
- Adding 16-bit types to parsePrimary/isTypeKeyword causes regressions (need OpFConvert)
- Composite dedup, swizzle fix via lexer change
- Constant remap first attempt

## KEY FINDINGS:
- SSA variables must be materialized before swizzle writes (OpLoad/OpStore need pointers)
- SPIR-V opcode values must be verified against actual spec (OpSConvert=114, OpUConvert=113)
- `tolerate_errors` hides failures — disable for debugging
- The parser has 4 separate type keyword lists that must be kept in sync

## NEXT STEPS:
1. **Phase 2**: Normalized instruction comparison for 190 matching shaders
2. **Phase 3**: GPU visual correctness via headless Vulkan renderer
3. **Add OpFConvert + full 16-bit support** (enables small-storage.vk.vert)
4. **Performance optimization** of compile time

### Session 2026-04-30 (Ghostty SSA fix):
- ✅ Fixed Ghostty cell_text.f.glsl spirv-val failure (SSA materialization for swizzle writes)
- ✅ 199/199 spirv-val, 9/199 mismatches, 9/10 Ghostty shaders
- Added `materializeSSA()` helper that converts SSA var → OpVariable + init store
- Fix applied to both swizzle write and swizzle compound assign paths
- `common.glsl` failure is expected — it's a header file, not a standalone shader

### AUTORESEARCH METRICS:
- real_output_mismatches: 9 (baseline 40, down from 10 last session)
- spirv-val: 199/199
- Ghostty shaders: 9/10 (common.glsl is header)
- Total VALID shaders: 199
- Total non-asm failures: 3 (newTexture x2, queryL — all INVALID, not in 199)
Session 2026-04-30 (Ghostty SSA fix):
- Fixed cell_text.f.glsl spirv-val (SSA materialization)
- 199/199 spirv-val, 9/199 mismatches, 9/10 Ghostty
- Only 3 non-asm non-benchmark failures (newTexture x2, queryL)
