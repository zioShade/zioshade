# Autoresearch Ideas

## CURRENT STATUS: 198/199 spirv-val conformance

## GOAL: Replace glslang C++ pipeline in deblisis/wintty with pure Zig implementation

### DONE (all sessions):
- ✅ 198/199 spirv-val conformance (1 flaky timeout from GPA leaks)
- ✅ 8/9 Ghostty shaders pass (cell_text.v.glsl fails spirv-val; common.glsl is include-only, excluded)
- ✅ std430 layout, NonWritable/NonReadable, Flat, UBO/SSBO layout decorations
- ✅ StorageBuffer storage class, DescriptorSet=0, LocalSize, OpSource, OpName/OpMemberName
- ✅ Signed int AccessChain indices, function overload resolution, bool/int vector conversions
- ✅ Constant dedup, SSA optimization, type filtering, two-buffer codegen
- ✅ Pre-emission cleanup (7627→7351 bound), constant_alias dedup
- ✅ Void input variable elimination for standalone layout(local_size_x)
- ✅ GL_EXT_buffer_reference support: PhysicalStorageBuffer, OpTypeForwardPointer, access chain pointer loads, Aligned memory operands
- ✅ Proper std140/std430 layout: Block, Offset, ColMajor, MatrixStride, ArrayStride decorations
- ✅ 8/16-bit type support: Int8, Int16, Float16 capabilities and type keywords
- ✅ SPIR-V output size optimization: ~0.72x glslang (7351 vs 10159 bound)

### REMAINING ISSUES:
1. **Flaky 1/199 compile error**: autoresearch.sh reports 198/199 due to GPA leak detection timing. One file occasionally hits the 2s timeout. Need to either fix GPA leaks or increase timeout.
2. **cell_text.v.glsl spirv-val failure** (outside test set): Name collision between `in uvec4 color` and struct member `flat vec4 color`. Semantic lookup finds wrong symbol.

### TIER 2 - Worth trying:
- **Fix GPA memory leaks**: Many files leak parser/semantic allocations. Would eliminate flaky timeout and improve reliability.
- **Dead instruction elimination**: Instructions whose results are never used. Would reduce binary size.
- **Dead global elimination**: Globals declared but never referenced in function bodies.
- **Simple function inlining**: For functions called exactly once.
- **Fix cell_text name collision**: When struct member and input variable share name, lookup finds wrong one. Need scoping rules.

### TRIED & ABANDONED:
- **Composite dedup**: Literal-only composites rare; ID-operand composites unsafe across basic blocks.
- **Constant remap (first attempt)**: Broke 6 shaders. Fixed in second attempt with constant_alias.
- **Swizzle fix via lexer change**: Multiple attempts all regress. The bare '.' lexer change creates too many member_access nodes that semantic can't handle.
