# Autoresearch Ideas

## CURRENT STATUS: 199/199 spirv-val, 10/10 Ghostty, 186/199 output match (13 real mismatches, all missing features)

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

### DONE (Session 2026-04-29):
- ✅ Array constructor syntax: float[](1.0, 2.0, 3.0) → OpCompositeConstruct for arrays
- ✅ Multi-dimensional array constructors: vec4[][](vec4[](1,2), vec4[](3,4))
- ✅ Struct array constructors: Foobar[](Foobar(10,40), Foobar(90,70))
- ✅ const + identifier type parsing: const StructName var = ...
- ✅ Identifier-based types in parseLocalVarDecl for struct names
- ✅ typesCompatible recursive comparison for array types (fixes pointer inequality)
- ✅ Lexer '.f' bug: tryParseNumber() now requires has_digit for number/float suffix acceptance
- ✅ Store mismatch count: 14 → 10 (fixed constant-array, constant-composites, ubo_layout, in-block-qualifiers)

### KEY FINDINGS:
- **Lexer .f bug was a major hidden issue**: Any struct member named 'f', 'flags', 'foo', etc. was broken because `.f` was tokenized as a float literal instead of dot + identifier
- **Zig caching**: Must `rm -rf .zig-cache/z` to force rebuild after code changes; incremental builds may use stale cache
- **tolerate_errors mode**: Silently catches semantic errors in function bodies, producing empty functions. Makes debugging hard.

### Session 2026-04-29 Summary:
- Fixed 6 store mismatches (14 → 8)
- Key fixes: lexer .f bug, typesCompatible for arrays, array constructors, anonymous block members
- All 199/199 spirv-val conformance maintained
- Remaining 8 mismatches require significant new features:
  - Input attachments (subpassInput)
  - Separate sampler/texture (sampler2D(tex, samp) → OpSampledImage)
  - nonuniformEXT qualifier
  - 8-bit arithmetic shader
  - Spec constants (OpSpecConstant)
  - Block-scoped struct redeclaration

### PROMISING NEXT STEPS:
- **OpSampledImage for separate sampler/texture**: sampler2D(tex, samp) creates combined image-sampler. Would fix 3 shaders (separate-sampler-texture x2, nonuniform-qualifier).
- **textureSize/textureQueryLevels/textureSamples without sampler**: samplerless texture functions.
- **input_attachment support**: subpassInput type + OpTypeImage with SubpassData dimensionality.
- **RelaxedPrecision decorations**: Quick win for 52 mediump shaders.

### DEFERRED (complex, significant new code):
- **Separate sampler/texture + OpSampledImage**: Needs new ast types (sampler, texture2D, etc.), lexer keywords, parser handling, semantic OpSampledImage construction, codegen support. Would fix 3+ shaders.
- **Input attachments**: Needs subpassInput type, OpTypeImage SubpassData, OpAttachmentImageRead. 2 shaders.
- **Spec constants**: Needs OpSpecConstant, layout(constant_id=...), SpecConstantOp. 1 shader.
- **Block-scoped struct redeclaration**: Needs per-scope type table. 1 shader.
- **8-bit arithmetic**: Needs Int8 capability and 8-bit operations. 1 shader.

### Session 2026-04-29 (Part 2):
- ✅ Added asinh(22), acosh(23), atanh(24) hyperbolic inverse GLSL.std.450 functions
- ✅ Functions returning array types (vec4[2] func()) — parser handles array dims on return types
- ✅ Fixed const_cache constant index lookup for cross-function constant reuse in index_access

### DISCOVERED ISSUES:
- **Swizzle writes don't work**: `v.xy = vec2(...)` produces no code. Single-component works (v.x = val), multi-component doesn't. Affects modf/frexp output parameter usage, many struct flattening shaders.
- **modf/frexp with vector types**: After Modf with scalar type, the next statement fails silently because multi-component swizzle writes aren't supported.
- The `tolerate_errors` mode hides these failures completely.

### IDEAS:
- **Implement multi-component swizzle writes**: For `v.xy = vec2(...)`, load current vector, OpVectorShuffle to combine, store back. Would fix modf/frexp output and many other patterns.
- **OpSampledImage for separate sampler/texture**: sampler2D(tex, samp) → OpSampledImage. Would fix 3 shaders.

### AUTORESEARCH FRAMEWORK (Session 2026-04-30):

#### PHASE 1: Reduce real_output_mismatches (22 → 0)
**Metric**: real_output_mismatches (lower is better)
**Baseline**: 22/199 (88.9% match, 18 false positives excluded)
**Tool**: autoresearch_bench.py — compares OpStore to Output/StorageBuffer vars, excludes gl_PerVertex wrapping

**Priority order for fixing 22 mismatches:**
1. **Logic bugs (8 shaders, closest to fixing):**
   - modf.legacy.frag: multi-component swizzle writes to output (result.xy, result.zw)
   - barycentric-khr-io-block.frag: out=2/8 — likely struct flattening
   - ground.vert: out=3/2 — off by 1, minor logic difference
   - ocean.vert: out=3/2 — off by 1
   - small-storage.vk.vert: out=1/3 — missing stores
   - switch-nested.legacy.vert: out=1/0 — extra store?
   - type-alias.comp: out=3/5 — struct aliasing issue
   - buffer-reference.nocompat.vk.comp: buf=0/9 — physical storage buffer stores missing

2. **Missing features (14 shaders, need new code):**
   - separate-sampler-texture*.frag (2 shaders) — OpSampledImage
   - input-attachment*.frag (2) — subpassInput
   - block-match-sad/ssd/box-filter/sample-weighted (4) — SPIR-V 1.4 subgroups?
   - nonuniform-qualifier (1) — nonuniformEXT
   - shader-arithmetic-8bit (1) — 8-bit ops
   - shader_ballot.comp (1) — subgroup ops
   - spec-constant-block-size (1) — spec constants
   - struct-type-unrelated-alias (1) — type aliasing
   - rq-position-fetch (1) — ray query position fetch

#### PHASE 2: Structural instruction match
Compare normalized SPIR-V disassembly instruction-by-instruction.

#### PHASE 3: GPU visual correctness
Headless Vulkan renderer, screenshot comparison, pixel diff metric.

#### PHASE 4: Performance optimization
Compile time, SPIR-V size, while maintaining 100% correctness.

#### BENCHMARK COMMAND:
```bash
python3 autoresearch_bench.py  # outputs METRIC real_output_mismatches=N
```
