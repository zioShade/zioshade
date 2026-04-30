# Autoresearch Ideas

## CURRENT STATUS: 199/199 spirv-val, 9/199 real output mismatches, 9/10 Ghostty shaders

## Session 2026-04-30:
### Correctness fixes (store counts unchanged, SPIR-V output quality improved):
1. ✅ SSA materialization for swizzle writes — fixed Ghostty cell_text.f.glsl
2. ✅ texelFetchOffset — ConstOffset (bit 3) + OpConstantComposite for constant vectors
3. ✅ textureLodOffset — Lod|ConstOffset in image_sample_explicit_lod
4. ✅ Shadow textureLodOffset — ConstOffset in image_sample_dref_explicit_lod
5. ✅ Shadow texture Bias/ConstOffset — Bias|ConstOffset in image_sample_dref
6. ✅ Added constant_composite IR tag for OpConstantComposite
7. ✅ constant_composite for scalar-to-vector splat of literal ints

## REMAINING 9 MISMATCHES (all vendor extensions):
- QCOM image processing (4): block-match-sad, block-match-ssd, box-filter, sample-weighted
- ARM tensors (3): tensor, tensor_params, tensor_read
- nonuniform-qualifier (1): needs nonuniformEXT + runtime arrays
- ray-query (1): needs ray tracing

## INFRASTRUCTURE ADDED:
- `materializeSSA()` helper in semantic.zig
- `constant_composite` IR tag + codegen for OpConstantComposite
- ConstOffset support in image_fetch, image_sample_explicit_lod, image_sample_dref_explicit_lod
- Bias support in image_sample_dref

## FUTURE WORK:
- textureOffset (non-shadow) — needs image_sample with ConstOffset mask
- textureGradOffset — needs Grad|ConstOffset
- OpFConvert + 16-bit types
- barrier() → proper OpControlBarrier
- Runtime arrays for nonuniform-qualifier
- Phase 2: Normalized instruction comparison
- Phase 3: GPU visual correctness

## KEY REFERENCE:
SPIR-V Image Operand bits: Bias=0, Lod=1, Grad=2, ConstOffset=3, Offset=4, ConstOffsets=5, Sample=6
