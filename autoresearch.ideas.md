# Autoresearch Ideas

## CURRENT STATUS: 199/199 spirv-val conformance, 10/10 Ghostty shaders

## GOAL: Replace glslang C++ pipeline in deblasis/wintty with pure Zig implementation

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
- ✅ VertexIndex=42/InstanceIndex=43 (Vulkan BuiltIn values, matching glslang)
- ✅ RowMajor/ColMajor decorations parsed and emitted correctly
- ✅ row_major propagation from parent blocks to nested struct matrix members
- ✅ Struct alignment: max member alignment (not hardcoded 16)
- ✅ row_major-aware matrix layout size: mat2x3 row_major std140 = 48 bytes (was 32)
- ✅ MatrixStride varies with row/col major in std430
- ✅ Array dimension nesting fixed: first dimension is outermost, matching GLSL semantics
- ✅ OpMemberDecorate NonWritable/NonReadable on block struct member 0 for readonly/writeonly SSBOs
- ✅ Coherent/Restrict/Volatile decorations for SSBO and image variables
- ✅ Invariant (18) decoration for invariant-qualified output variables
- ✅ UniformConstant storage class for sampler/image variables (was Uniform)
- ✅ For-loop empty init/condition/update fix: parser always emits 4 children
- ✅ Comma-separated variable declarations via multi_decl AST tag (no scope push/pop)
- ✅ Comma operator in for-loop condition/update expressions (comma_op AST tag)
- ✅ uint post-increment: uses getConstInt instead of getConstFloat
- ✅ OpSwitch implementation with case labels, SelectionMerge, break, fall-through
- ✅ if_stmt fix: handles break/continue/kill inside if-then/else (avoids double branch)
- ✅ OpKill for GLSL discard statements (was silently ignored)
- ✅ Uint literal parsing: strip 'u' suffix before parseInt (was always 0)
- ✅ texelFetch Lod image operand mask fix (bit 1 = value 2, was bit 0 = value 1 = Bias)
- ✅ SSA variable un-SSA for for-loops: force materialize all SSA vars before loop header
- ✅ if-else dead code: save/restore has_returned to prevent if-body return from suppressing else-body
- ✅ for-loop-init.frag: 10/10 stores matching glslang (was 6/10)
- ✅ Coarse/fine derivative functions: dFdxCoarse/dFdyCoarse/fwidthCoarse/dFdxFine/dFdyFine/fwidthFine
- ✅ DerivativeControl capability: value=51 (was incorrectly 28)
- ✅ SPIR-V capability enum fixes: sampled_image_array_dynamic_indexing=29, image_cube_array=34, sample_rate_shading=35, int64=11
- ✅ textureQueryLod support (OpImageQueryLod opcode 105)

### TIER 1 - Correctness improvements (beyond spirv-val):
- **ConstOffset for textureLodOffset/texelFetchOffset**: Requires emitting offsets as OpConstantComposite (compile-time constants) instead of OpCompositeConstruct (runtime). Currently offsets are dropped.
- **Type aliasing for std140/std430**: When the same struct is used in both std140 and std430 blocks, glslang creates separate type aliases (Content vs Content_0) with different offset decorations. We use a single type, so offsets can only be correct for one layout. Requires significant change to emitType system.
- **Fix GPA memory leaks**: ~90 files leak parser/semantic allocations (dupeNodes is #1 source). Would make Debug builds reliable.
- **RelaxedPrecision decorations**: 52 shaders use mediump precision. glslang emits RelaxedPrecision on mediump variables and expressions.
- **NoContraction decorations**: precise qualifier should prevent operation reordering. Affects no-contraction.vert.

### TIER 2 - Feature completeness:
- **OpLine debug information**: Add source line mapping to SPIR-V output for better debugging.
- **Spec constant support**: OpSpecConstant for specialization constants.
- **gl_PerVertex block wrapping**: Structurally different from glslang but functionally equivalent. Low priority.

### TRIED & ABANDONED:
- **Composite dedup**: Literal-only composites rare; ID-operand composites unsafe across basic blocks.
- **Constant remap (first attempt)**: Broke 6 shaders. Fixed in second attempt with constant_alias.
- **Swizzle fix via lexer change**: Multiple attempts all regress. The bare '.' lexer change creates too many member_access nodes that semantic can't handle.
- **cell_text name collision**: FIXED — in/out block members no longer directly accessible as symbols.
