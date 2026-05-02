# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Commit: bc822d7 (Float64 for double tensors → perfect score)

## CURRENT METRICS:
- 199/199 spirv-val ✅
- 0/199 output store mismatches (100% match!) ✅
- 0 total failures ✅
- 149/149 gap tests ✅
- Total bound: 10881 across 199 shaders

## PHASE 1 COMPLETE ✅
All output store mismatches resolved. Perfect correctness achieved.

## PHASE 4: SPIR-V Output Size Optimization
- Baseline: 10881 total bound across 199 shaders
- Average ratio vs glslang: ~0.79x (we're already smaller on average)
- Some shaders are 2x+ larger than glslang (atomic.comp, array-of-buffer-reference)

## OPTIMIZATION IDEAS:
- **Constant composite dedup in codegen**: Prevents emitting duplicate OpConstantComposite instructions. Works but doesn't reduce bound (IDs pre-allocated in semantic analysis). Reduces actual binary size.
- **ID compaction pass**: Remap SPIR-V IDs to eliminate gaps from dedup. Requires full opcode table for correct ID position identification. Complex but high impact.
- **Semantic-level constant composite dedup**: Before allocId(), check if same (type, operands) already exists. Would reduce bound by preventing duplicate ID allocation.
- **Dead constant elimination**: Remove constants that are defined but never referenced. Requires use-def analysis across all sections.
- **Type dedup improvements**: Already done for simple types, tensor types. Could extend to struct types with same layout.
- **Instruction selection**: Some patterns emit more instructions than needed (e.g., separate OpBitcast for each int→uint conversion when a single OpCompositeConstruct with type coercion would suffice).

## IMPLEMENTED THIS SESSION (Phase 1):
1. ARM tensor type support (tensorARM<type,N>, OpTypeTensorARM, tensorSizeARM/tensorReadARM builtins)
2. int32_t/uint32_t/float32_t as lexer keywords mapping to int/uint/float
3. Unnamed function parameters
4. gl_TensorOperandsOutOfBoundsValueARM constant
5. uint8→float conversion in getConversionTag
6. Array constant composite with uint base (uint[](1,2,3))
7. Float64 capability for double tensor types
8. Tensor type dedup by (element_type, rank)
9. Transitive AccessChain tracking in benchmark

## PHASE 4 OPTIMIZATION ATTEMPTS (2026-05-01):
- **constant_composite codegen dedup**: Works, reduces binary size but not bound (IDs pre-allocated). Need semantic-level dedup for bound reduction.
- **ID compaction pass**: Too risky without full opcode table. Would need to know which words are IDs vs literals for every opcode.
- **Load caching**: Too aggressive via constant_alias. Caused massive regression. Would need per-block mapping without global aliasing.
- **Struct type dedup**: Multiple struct types with same layout are emitted separately. Could share types.
- **SSA variable elimination**: Variables stored once and loaded once could be replaced with direct value propagation. Requires use-def analysis.

## Session 2026-05-01 (Phase 4 continued):
- **Semantic-level constant composite dedup**: IMPLEMENTED (-309 IDs). Cache key (type, operand_ids) prevents duplicate OpConstantComposite and element constants.
- **AccessChain caching within basic blocks**: IMPLEMENTED (-217 IDs). Clear at labels/functions for dominance. 
- **Load caching within basic blocks**: IMPLEMENTED (-168 IDs). Clear at labels, functions, and stores. PITFALL: must also clear at function boundaries (cross-function caching causes dominance violations).
- **Pure op CSE (composite_extract)**: IMPLEMENTED (-12 IDs). Modest gain.
- **Per-pointer store invalidation**: Investigated but too complex (aliasing concerns).
- **Dead instruction elimination**: 568 dead IDs total (296 labels, 45 loads, 43 function calls, 29 constants). Hard to eliminate at semantic level without lazy evaluation.
- **ID compaction pass**: Requires remapping IDs in both IR and codegen. High risk without complete opcode ID-position table.
- **Cross-block load caching**: 322 remaining duplicate loads across block boundaries. Requires dominance analysis.
- **Additional pure op caching**: vector_shuffle (15 dups), bitcast (15 dups), image_texel_pointer (12 dups). Potential ~40 more IDs but requires restructuring to check cache before allocId.
- **Total progress**: 10881 → 10175 (-706 IDs, -6.5%)

## Session 2026-05-01 (Phase 4 continued - iteration 2):
- **Targeted store invalidation**: IMPLEMENTED (-138 IDs). Only remove stored-to ptr from load_cache instead of clearing entire cache. Stores to output vars don't affect uniform/input loads.
- **Vector shuffle dedup**: IMPLEMENTED (-28 IDs). Converted 5 vector_shuffle emission sites to emitPureOp.
- **ImageTexelPointer dedup**: IMPLEMENTED (-12 IDs). Converted to emitPureOp.
- **Transpose dedup attempt**: Works for dedup but doesn't reduce bound (result_id pre-allocated). `next_id -= 1` rollback causes ID collisions in codegen.
- **Rollback lesson**: `next_id -= 1` is UNSAFE because `module.next_id_start = analyzer.next_id` and codegen starts allocating from that value. Lowering it causes codegen IDs to collide with IR IDs.
- **CompositeConstruct dedup**: Only 2 duplicates across all shaders. Not worth converting.
- **Remaining duplicates**: 291 total. 190 OpLoad (cross-block), 21 OpAccessChain (cross-block), 18 OpBitcast (pre-allocated). Need dominance analysis or pre-allocation restructuring for further gains.
- **Total progress this session**: 10881 → 9997 (-884 IDs, -8.1%)

## Session 2026-05-01 (Phase 4 - iteration 3):
- **Cross-block load caching for global pointers**: IMPLEMENTED (-36 IDs). global_load_cache persists across blocks (only cleared at function boundaries). Only populated from entry block to avoid dominance violations.
- **Dominance pitfall**: Can only cache loads from the entry block (which dominates all blocks). Caching from conditional blocks causes "ID does not dominate its use" spirv-val errors.
- **Remaining 157 OpLoad duplicates**: Cross-block loads from non-entry blocks, function-local pointers, sub-function loads. Would need per-block load caching with dominance analysis for further gains.
- **Total progress**: 10881 → 9961 (-920 IDs, -8.5%), all 7 optimizations combined.
- **Future ideas**:
  - Per-function global_load_cache (pre-populate from entry block, pass to sub-functions)
  - AccessChain caching across blocks (currently cleared at labels for dominance safety)
  - Pre-allocation restructuring for transpose/bitcast to enable emitPureOp for those ops
  - Dead code elimination at IR level (568 dead IDs, but doesn't reduce bound without compaction)

## Session 2026-05-01 (Phase 4 - iteration 4):
- **Scalar splat constant composite cache**: IMPLEMENTED (-8 IDs). Check const_composite_cache before allocating splat_id in binary op scalar-to-vector splat. Prevents duplicate vec2(10.0, 10.0) etc.
- **General composite_construct fallback cache**: IMPLEMENTED (-2 IDs). Check cache for all-constant composites in the general type_constructor path.
- **Struct constructor cache attempt**: REVERTED. constCompositeKey uses @intFromEnum(ty) which doesn't distinguish named types. Would need to hash the type name string for named types. Only saves 1 ID, not worth the risk.
- **False alarm: 1025 waste IDs**: The earlier analysis using symbolic disassembly names was completely wrong. Using `--raw-id` flag, actual waste is only 49 IDs across all 199 shaders.
- **Cross-block cache attempt**: REVERTED. Tried to preserve caches across unconditional branches (only clear after conditional branches). Caused dominance violations because unconditional branch from then-block to merge doesn't mean then-block dominates merge.
- **Total progress**: 10881 → 9951 (-930 IDs, -8.5%), all 9 optimizations combined.
- **Remaining optimization opportunities**:
  - Fix constCompositeKey for named types (hash the type name string too) — would save 1 more ID
  - Cross-block load caching with dominance analysis (157 remaining OpLoad duplicates)
  - ID compaction pass at codegen level (only 49 IDs waste)
  - The optimization is approaching diminishing returns — further gains require complex analysis

## Session 2026-05-01 (Phase 4 - iteration 5):
- **Global AccessChain cache**: IMPLEMENTED (-15 IDs). AccessChains from entry block persist across all blocks.
- **Struct layout dedup**: IMPLEMENTED (-41 IDs). emitted_struct_layouts cache keyed by member type IDs. All 28 OpTypeStruct duplicates eliminated.
- **Conversion site emitPureOp**: IMPLEMENTED (-17 IDs). Converted 6 conversion emission sites to use emitPureOp. Eliminated 14 of 18 OpBitcast duplicates.
  - Key learning: sites using pre-allocated result_id from outer scope MUST keep using it. Converting to emitPureOp wastes the pre-allocated ID. Only convert sites that allocate their own conv_id.
  - Reverted one site (vector conversion in type_constructor) that caused +9 regression.
- **Bitcast pre-check**: Added to GLSL builtin handler. Checks pure_op_cache before allocating result_id for bitcast builtins.
- **Total progress**: 10881 → 9877 (-1004 IDs, -9.2%), 199/199 pass, 0 mismatches
- **Remaining duplicates**: 4 OpBitcast, ~155 OpLoad, 11 OpAccessChain, 6 OpConvertSToF, 6 OpCompositeExtract
