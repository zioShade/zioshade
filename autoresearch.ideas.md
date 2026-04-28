# Autoresearch Ideas

## CURRENT STATUS: 197/197 spirv-val, 9/10 Ghostty shaders pass

## GOAL: Replace glslang C++ pipeline in deblisis/wintty with pure Zig implementation

### DONE (all sessions):
- ✅ std430 layout fix: correct ArrayStride and offset computation for std430 buffers
- ✅ NonWritable/NonReadable decorations for readonly/writeonly SSBOs
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
- Complex to implement correctly: need to remap variable IDs, emit AccessChain
- Risk: could break vertex shaders. Benefit: structural equivalency.
- Attempted and reverted once — need cleaner approach.

### TIER 2 - Minor improvements:
- SPIR-V version: emit 1.0 for ESSL targets, 1.3+ for Vulkan (detect from #version)
- Flat/Centroid/Component decorations on IO variables (need qualifier tracking for flat/smooth/noperspective)
- RelaxedPrecision decoration for mediump operations (glslang emits these)
- OpSource version detection from #version directive

### TIER 3 - Performance (already good at 0.73x bound for aggregate metrics):
- Function inlining (high effort)
- Dead type elimination
- Constant folding
- Note: individual simple shaders can be larger than glslang (1.06-1.24x) due to extra type/constant IDs
