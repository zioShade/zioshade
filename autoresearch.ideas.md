# Autoresearch Ideas

## CURRENT STATUS: 199/199 spirv-val, 9/199 real output mismatches, 9/10 Ghostty shaders

## Session 2026-04-30 (Part 2):
- ✅ Fixed Ghostty cell_text.f.glsl SSA materialization for swizzle writes
- ✅ Fixed texelFetchOffset: ConstOffset (bit 3=8) + OpConstantComposite for offsets
- ✅ Fixed textureLodOffset: Lod|ConstOffset in image_sample_explicit_lod
- ✅ Fixed shadow textureLodOffset: ConstOffset in image_sample_dref_explicit_lod
- ✅ Added constant_composite IR tag + codegen for OpConstantComposite
- ✅ Added constant_composite for scalar-to-vector splat of literal ints
- All fixes are correctness improvements (store counts unchanged)

## REMAINING 9 MISMATCHES (all vendor extensions):
- QCOM image processing (4): block-match-sad, block-match-ssd, box-filter, sample-weighted
- ARM tensors (3): tensor, tensor_params, tensor_read
- nonuniform-qualifier (1): needs nonuniformEXT, runtime arrays
- ray-query (1): needs ray tracing

## TRIED THIS SESSION:
- newTexture.frag sampler2DRect texelFetchOffset: needs different arg handling for Rect samplers (no Lod). Skipped — INVALID shader.
- textureOffset shadow with bias: needs ConstOffset|Bias for image_sample_dref. Skipped — complex.

## STILL TO DO:
- textureOffset (implicit lod with offset): image_sample with ConstOffset mask=8
- textureGatherOffsets: needs ConstOffsets (plural, bit 5) with array of offsets
- OpFConvert + full 16-bit support
- barrier() → proper OpControlBarrier/OpMemoryBarrier
- Phase 2: Normalized instruction comparison
- Phase 3: GPU visual correctness

## KEY FINDINGS THIS SESSION:
- SPIR-V Image Operand bits: Bias=0, Lod=1, Grad=2, ConstOffset=3, Offset=4, ConstOffsets=5, Sample=6
- ConstOffset requires OpConstantComposite (NOT OpCompositeConstruct)
- ConstOffset word count: OpImageFetch(8), OpImageSampleExplicitLod(8), OpImageSampleDrefExplicitLod(9)
