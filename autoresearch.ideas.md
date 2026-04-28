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

### DONE: Pre-emission cleanup
Removed all speculative pre-emissions from emitTypesAndConstants:
- Atomic constants (1, 64, 0) — two-buffer handles it
- Float/void ensureType — on-demand
- vec2/vec3 for shadow samplers — two-buffer handles it
- Float_0 for image_sample — two-buffer handles it
- Literal int constants for access_chain/composite_extract/vector_shuffle — two-buffer
- image_texel_pointer pointer type — two-buffer
Result: 7627 → 7351 bound (-3.6%)
Also added constant_alias dedup for constant_int/constant_float in function codegen.

### NEXT: Reduce ID bound overhead (TIER 2)
Remaining overhead (~0.73x of glslang):
- **Function inlining**: ground.vert has 8 functions vs glslang's 3. Each extra function costs ~15 IDs (type, params, labels, locals). Single-call-site inlining would help.
- **Constant composite dedup**: Duplicate `v2float(0.5, 0.5)` constructions exist in ground.vert
- Dead global elimination (globals declared but never used in functions)
- Dead constant elimination (constants emitted but never referenced)

### COMPOSITE DEDUP (tried, minimal impact)
Attempted constant composite dedup but:
- Literal-only composites are rare (most use ID operands)
- ID-operand composites can't be safely deduped (SSA dominance issues across basic blocks)
- Even when dedup works, aliased IDs still allocated so bound doesn't change
- Not worth the complexity
- Centroid/NoPerspective/Sample decorations on IO variables (low priority)
- RelaxedPrecision decoration for mediump operations (glslang emits these)
- OpSource version detection from #version directive

### TIER 1 (deferred - high risk):
- gl_PerVertex Block wrapping: complex, cosmetic, attempted+reverted once
  - Our standalone gl_Position with BuiltIn Position works correctly for all drivers
  - Only needed for structural equivalency, not correctness
