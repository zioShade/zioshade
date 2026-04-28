# Autoresearch Ideas

## CURRENT STATUS: 197/197 spirv-val, 9/9 Ghostty shaders (common.glsl is include-only)

## GOAL: Replace glslang C++ pipeline in deblisis/wintty with pure Zig implementation

### DONE (all sessions):
- ✅ std430 layout, NonWritable/NonReadable, Flat, UBO/SSBO layout decorations
- ✅ StorageBuffer storage class, DescriptorSet=0, LocalSize, OpSource, OpName/OpMemberName
- ✅ Signed int AccessChain indices, function overload resolution, bool/int vector conversions
- ✅ Constant dedup, SSA optimization, type filtering, two-buffer codegen
- ✅ Pre-emission cleanup (7627→7351 bound), constant_alias dedup
- ✅ Void input variable elimination for standalone layout(local_size_x)

### TRIED & ABANDONED:
- **Composite dedup**: Literal-only composites rare; ID-operand composites unsafe across basic blocks; aliased IDs still allocated. Not worth complexity.
- **Constant remap (first attempt)**: Broke 6 shaders because operandValue/AccessChain didn't remap. Fixed in second attempt with constant_alias.

### TIER 2 - Worth trying:
- **Dead instruction elimination**: Instructions whose results are never used (e.g. dead loads, dead composites). Would reduce binary size and potentially bound.
- **Dead global elimination**: Globals declared but never referenced in function bodies. Would reduce entry point interface.
- **Simple function inlining**: For functions called exactly once — expand body at call site. ground.vert: 8 funcs vs glslang's 3.
- **Centroid/NoPerspective/Sample decorations** on IO variables (low priority)
- **OpSource version detection** from #version directive (emit 1.0 for ESSL, 1.3+ for Vulkan)

### TIER 1 (deferred - high risk):
- gl_PerVertex Block wrapping: cosmetic only, standalone gl_Position with BuiltIn works
- Function inlining for multi-call-site functions: very complex
