# Autoresearch Ideas

## CURRENT STATUS: 197/197 spirv-val, 9/10 Ghostty shaders pass

## GOAL: Replace glslang C++ pipeline in deblisis/wintty with pure Zig implementation

### DONE (all sessions):
- ✅ std430 layout fix: correct ArrayStride and offset computation for std430 buffers
- ✅ NonWritable/NonReadable decorations for readonly/writeonly SSBOs
- ✅ Flat decoration (14) for flat-qualified IO variables
- ✅ UBO/SSBO layout decorations: Block, Offset, ColMajor, MatrixStride, ArrayStride (recursive)
- ✅ StorageBuffer storage class for SSBOs
- ✅ Default DescriptorSet=0 for UBO/SSBO with binding
- ✅ Compute shader LocalSize execution mode
- ✅ OpSource GLSL 450 directive
- ✅ OpName/OpMemberName for struct types
- ✅ Signed int for AccessChain indices
- ✅ Function overload resolution, bool-to-float, int-to-float vector conversion, pack/unpack builtins
- ✅ Constant dedup, pointer type pre-emit, SSA optimization, type filtering, two-buffer codegen

### NEXT: Reduce ID bound overhead (TIER 2)
Individual simple shaders are 1.06-1.39x larger than glslang due to extra type/constant IDs.
Ideas:
- **Constant dedup gap**: pre-scan emits constants (via emitIntConstant), function codegen also emits constants (via constant_int IR). Both create separate IDs for same value. Attempted constant_remap but broke 6 shaders. Needs IR-level fix.
- Deduplicate pointer types more aggressively
- Dead type elimination pass
- Note: overhead is structural and acceptable for correctness

### TIER 2 - Minor improvements:
- Centroid/NoPerspective/Sample decorations on IO variables (low priority)
- RelaxedPrecision decoration for mediump operations (glslang emits these)
- OpSource version detection from #version directive

### TIER 1 (deferred - high risk):
- gl_PerVertex Block wrapping: complex, cosmetic, attempted+reverted once
  - Our standalone gl_Position with BuiltIn Position works correctly for all drivers
  - Only needed for structural equivalency, not correctness
