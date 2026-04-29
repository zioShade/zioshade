# Autoresearch Ideas

## CURRENT STATUS: 197/199 spirv-val (2 remaining)

## GOAL: Replace glslang C++ pipeline in deblisis/wintty with pure Zig implementation

### DONE (all sessions):
- ✅ std430 layout, NonWritable/NonReadable, Flat, UBO/SSBO layout decorations
- ✅ StorageBuffer storage class, DescriptorSet=0, LocalSize, OpSource, OpName/OpMemberName
- ✅ Signed int AccessChain indices, function overload resolution, bool/int vector conversions
- ✅ Constant dedup, SSA optimization, type filtering, two-buffer codegen
- ✅ Pre-emission cleanup (7627→7351 bound), constant_alias dedup
- ✅ Void input variable elimination for standalone layout(local_size_x)
- ✅ GL_EXT_buffer_reference support: PhysicalStorageBuffer, OpTypeForwardPointer, access chain pointer loads, Aligned memory operands

### REMAINING 2 FAILURES:
1. **buffer-reference-bitcast-uvec2-2.nocompat.invalid.vk.comp**: `uvec2(ptrint)` — converting PhysicalStorageBuffer pointer to uvec2. Needs OpConvertPtrToU or OpBitcast. Very specialized.
2. **small-storage.vk.vert**: 8/16-bit types (uint16_t, float16_t, i16vec4, etc.). Needs Int8, Int16, Float16 capabilities and many new type keywords.

### TIER 2 - Worth trying:
- **8/16-bit type support**: Add uint16_t, int16_t, float16_t, i16vec2-4, u16vec2-4, f16vec2-4, uint8_t, int8_t, i8vec2-4, u8vec2-4 to lexer. Map to SPIR-V 8/16-bit types. Add Int8=39, Int16=6, Float16=22 capabilities. Would fix small-storage.vk.vert.
- **Dead instruction elimination**: Instructions whose results are never used. Would reduce binary size.
- **Dead global elimination**: Globals declared but never referenced in function bodies.
- **Simple function inlining**: For functions called exactly once.

### TRIED & ABANDONED:
- **Composite dedup**: Literal-only composites rare; ID-operand composites unsafe across basic blocks.
- **Constant remap (first attempt)**: Broke 6 shaders. Fixed in second attempt with constant_alias.
