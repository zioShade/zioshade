# Autoresearch Ideas

## CURRENT STATUS: 199/199 spirv-val, 9/199 real output mismatches, 9/10 Ghostty shaders

## Session 2026-04-30 (Part 3):
### Infrastructure added:
- ✅ OpFConvert (opcode 115) + `convert_ftof` IR tag
- ✅ Float16 conversion in getConversionTag (float↔float16, int/uint→float16)
- ✅ Float16 result_scalar in scalar-to-vector splat path
- ✅ Float16 vector arg_scalar in multi-arg constructor path

### Key finding:
- 16-bit vector types (i16vec*, u16vec*, f16vec*) MUST NOT be in `isTypeKeyword` or `parsePrimary` type constructor list
- Reason: `spv.nvAtomicFp16Vec.frag` (VALID shader) uses NV atomic fp16 vector operations
- When f16vec2 is recognized, parser produces f16vec2(3) → broken atomic operations
- Before: parser ignored f16vec2 → tolerate_errors → empty function body → passes spirv-val
- Solution: Keep 16-bit types in `tryType()` for declarations only, NOT as type constructors

### TRIED & REVERTED:
- Adding i16vec/u16vec/f16vec to isTypeKeyword → spv.nvAtomicFp16Vec.frag regression

## REMAINING 9 MISMATCHES (all vendor extensions):
- QCOM image processing (4)
- ARM tensors (3)
- nonuniform-qualifier (1) — needs runtime arrays + nonuniformEXT
- ray-query (1) — needs ray tracing

## FUTURE WORK:
- Enable 16-bit type constructors when NV atomic fp16 is properly supported
- textureOffset (non-shadow) — ConstOffset for image_sample
- barrier() → proper OpControlBarrier
- Phase 2: Normalized instruction comparison
- Phase 3: GPU visual correctness
