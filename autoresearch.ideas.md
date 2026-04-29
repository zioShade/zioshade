# Autoresearch Ideas

## CURRENT STATUS: 199/199 spirv-val conformance, 10/10 Ghostty shaders

## GOAL: Replace glslang C++ pipeline in deblisis/wintty with pure Zig implementation

### DONE (all sessions):
- ✅ 199/199 spirv-val conformance
- ✅ 10/10 Ghostty shaders pass
- ✅ std430 layout, NonWritable/NonReadable, Flat, UBO/SSBO layout decorations
- ✅ StorageBuffer storage class, DescriptorSet=0, LocalSize, OpSource, OpName/OpMemberName
- ✅ Signed int AccessChain indices, function overload resolution, bool/int vector conversions
- ✅ Constant dedup, SSA optimization, type filtering, two-buffer codegen
- ✅ Pre-emission cleanup (7627→7351 bound), constant_alias dedup
- ✅ Void input variable elimination for standalone layout(local_size_x)
- ✅ GL_EXT_buffer_reference support: PhysicalStorageBuffer, OpTypeForwardPointer, access chain pointer loads, Aligned memory operands
- ✅ Proper std140/std430 layout: Block, Offset, ColMajor, MatrixStride, ArrayStride decorations
- ✅ 8/16-bit type support: Int8, Int16, Float16 capabilities and type keywords
- ✅ SPIR-V output size optimization: ~0.73x glslang (9030 vs 12351 total bound across 199 shaders)
- ✅ Centroid (16) and NoPerspective (13) decorations for IO variables
- ✅ In/out block member scoping fix: only uniform/buffer/push_constant members directly accessible
- ✅ ReleaseSafe build to avoid GPA leak detection overhead

### TIER 1 - Correctness improvements (beyond spirv-val):
- **Fix GPA memory leaks**: ~90 files leak parser/semantic allocations (dupeNodes is #1 source). Would make Debug builds reliable. Root cause: GPA allocations in parser/semantic not freed when compileToSPIRV returns.
- **Dead instruction elimination**: Instructions whose results are never used. Would reduce binary size.
- **Dead global elimination**: Globals declared but never referenced in function bodies.

### TIER 2 - Feature completeness:
- **OpLine debug information**: Add source line mapping to SPIR-V output for better debugging.
- **Spec constant support**: OpSpecConstant for specialization constants.
- **gl_PerVertex block wrapping**: Structurally different from glslang but functionally equivalent. Low priority.

### TRIED & ABANDONED:
- **Composite dedup**: Literal-only composites rare; ID-operand composites unsafe across basic blocks.
- **Constant remap (first attempt)**: Broke 6 shaders. Fixed in second attempt with constant_alias.
- **Swizzle fix via lexer change**: Multiple attempts all regress. The bare '.' lexer change creates too many member_access nodes that semantic can't handle.
- **cell_text name collision**: FIXED — in/out block members no longer directly accessible as symbols.
