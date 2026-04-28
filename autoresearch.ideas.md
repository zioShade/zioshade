# Autoresearch Ideas

## CURRENT STATUS: 197/197 spirv-val, 9/10 Ghostty shaders pass

## GOAL: Replace glslang C++ pipeline in deblisis/wintty with pure Zig implementation

### DONE this session:
- ✅ UBO/SSBO layout decorations: Block, Offset, ColMajor, MatrixStride, ArrayStride (recursive for nested structs/arrays)
- ✅ StorageBuffer storage class for SSBOs (no more deprecated BufferBlock)
- ✅ Default DescriptorSet=0 for UBO/SSBO with binding
- ✅ Standalone layout(local_size_x=N) in; parsing for compute LocalSize
- ✅ OpSource GLSL 450 directive
- ✅ OpName/OpMemberName for struct types (named structs instead of _struct_N)

### REMAINING for full glslang equivalency:
TIER 1 - Structural differences (functionally equivalent but different structure):
- gl_PerVertex Block wrapping: glslang wraps gl_Position/gl_PointSize in gl_PerVertex struct with Block + BuiltIn decorations
  - Our approach (standalone gl_Position with BuiltIn) works for spirv-val but differs from glslang
  - Medium effort, high visual equivalency impact

TIER 2 - Minor improvements:
- Index type for AccessChain: use int (signed) instead of uint for struct member indices
- SPIR-V version: emit 1.0 for ESSL targets, 1.3+ for Vulkan
- Generator ID: could set to custom value
- NonWritable/NonReadable decorations for readonly/writeonly buffers
- Flat/Centroid/Component decorations on IO variables
- OpSource version detection from #version directive

TIER 3 - Performance (already good at 0.73x bound):
- Function inlining (high effort)
- Dead type elimination
- Constant folding
