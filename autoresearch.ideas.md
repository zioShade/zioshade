# Autoresearch Ideas

## CURRENT STATUS: 197/197 spirv-val, 9/10 Ghostty shaders pass

## GOAL: Replace glslang C++ pipeline in deblasis/wintty with pure Zig implementation

### DONE (all sessions):
- ✅ UBO/SSBO layout decorations: Block, Offset, ColMajor, MatrixStride, ArrayStride (recursive)
- ✅ StorageBuffer storage class for SSBOs
- ✅ Default DescriptorSet=0 for UBO/SSBO with binding
- ✅ Standalone layout(local_size_x=N) in; parsing for compute LocalSize
- ✅ OpSource GLSL 450 directive
- ✅ OpName/OpMemberName for struct types
- ✅ Signed int for AccessChain indices
- ✅ Function overload resolution fix
- ✅ Bool-to-float/int/uint conversion
- ✅ Int vector → float vector conversion
- ✅ Pack/unpack builtin detection
- ✅ Constant dedup, pointer type pre-emit, SSA optimization, type filtering, two-buffer codegen

### NEXT: gl_PerVertex Block wrapping (TIER 1)
- glslang wraps gl_Position/gl_PointSize in gl_PerVertex struct with Block + BuiltIn decorations
- Our approach (standalone gl_Position with BuiltIn) works for spirv-val but differs from glslang
- Required for: full structural equivalency with glslang
- Approach: In codegen, for vertex shaders, detect gl_Position output and wrap in synthetic gl_PerVertex struct
  - Create struct type { vec4, float } with Block + BuiltIn Position/PointSize decorations
  - Replace gl_Position variable with gl_PerVertex struct variable
  - Rewrite stores to gl_Position → AccessChain(0) + OpStore
- Risk: complex change, could break many vertex shaders. Must test thoroughly.

### TIER 2 - Minor improvements:
- SPIR-V version: emit 1.0 for ESSL targets, 1.3+ for Vulkan (detect from #version)
- NonWritable/NonReadable decorations for readonly/writeonly buffers
- Flat/Centroid/Component decorations on IO variables
- OpSource version detection from #version directive
- RelaxedPrecision decoration for mediump operations (glslang emits these)

### TIER 3 - Performance (already good at 0.73x bound):
- Function inlining (high effort)
- Dead type elimination
- Constant folding
