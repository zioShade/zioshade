# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Commit: 565b1ac (Codegen dref extraction cache)

## CURRENT METRICS:
- 199/199 spirv-val ✅
- 0/199 output store mismatches (100% match!) ✅
- 0 total failures ✅
- 149/149 gap tests ✅
- Total bound: 9809 across 199 shaders (-9.9% from 10881)

## PHASE 1 COMPLETE ✅
All output store mismatches resolved. Perfect correctness achieved.

## PHASE 4: SPIR-V Output Size Optimization
- Baseline: 10881 total bound across 199 shaders
- Current: 9809 (-1072 IDs, -9.9%)
- Average ratio vs glslang: ~0.79x (we're already smaller on average)

## OPTIMIZATIONS IMPLEMENTED (this session):
1. Semantic-level constant composite dedup (-309 IDs)
2. AccessChain caching within basic blocks (-217 IDs)
3. Load caching within basic blocks (-168 IDs)
4. Pure op CSE for composite_extract (-12 IDs)
5. Targeted store invalidation (-138 IDs)
6. Vector shuffle dedup via emitPureOp (-28 IDs)
7. ImageTexelPointer dedup via emitPureOp (-12 IDs)
8. Cross-block load caching for global pointers from entry block (-36 IDs)
9. Scalar splat constant composite cache (-8 IDs)
10. General composite_construct fallback cache (-2 IDs)
11. Struct layout dedup in codegen (-41 IDs)
12. Conversion sites to emitPureOp (-17 IDs)
13. Unary op emitPureOp (-9 IDs)
14. Binary op pure_op_cache pre-check (-15 IDs)
15. Extract image dedup via emitPureOp (-4 IDs)
16. Index access via emitAccessChainCached + emitPureOp (-34 IDs)
17. Codegen dref extraction + coordinate shrink cache (-6 IDs)

## REMAINING OPTIMIZATION OPPORTUNITIES:
- **Cross-block load caching with dominance analysis**: 148 OpLoad duplicates remain, all cross-block or store-invalidated. Would need per-block load caching with dominance frontier analysis.
- **ID compaction pass**: Remap SPIR-V IDs to eliminate gaps. Would recover ~49 wasted IDs. Requires full opcode ID-position table.
- **Dead code elimination**: 534 dead IDs total (293 labels, 43 function calls, 39 loads, 29 constants). Doesn't reduce bound without compaction.
- **SSA variable elimination**: 21 variables stored once and loaded once. Could save ~63 IDs. Requires use-def analysis.
- **Dead variable elimination**: 200 variables stored but never loaded. Could eliminate stores and computing expressions.
- **Moving result_id allocation in function_call handler**: Would enable emitPureOp for ext_inst and conversions, saving ~10 IDs. Complex refactoring.

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

## Session 2026-05-01 (Phase 4 - iteration 6):
- **Binary op pure_op_cache pre-check**: IMPLEMENTED (-15 IDs). Moved result_id allocation AFTER cache check. Covers fadd, iadd, fsub, isub, fmul, imul, fdiv, idiv, fmod, umod, rem, bit_and, bit_or, bit_xor, shift_left, shift_right. Excludes comparison operators.
  - Key technique: moved allocId AFTER cache check so no IDs are wasted on cache hits.
  - Eliminated: OpFAdd (5→0), OpIAdd (4→0), OpBitwiseAnd (3→0), OpSNegate (was already 0 from unary conversion).
- **Total progress**: 10881 → 9853 (-1028 IDs, -9.4%), 199/199 pass, 0 mismatches
- **Remaining duplicates**: 509 total. OpVariable 208, OpLoad 155, OpFunctionParameter 45, OpFunction 40 (all can't dedup). Actionable: OpAccessChain 11, OpCompositeExtract 6, OpBitcast 4, OpCompositeConstruct 4, OpImage 4, OpExtInst 3.

## Session 2026-05-01 (Phase 4 - iteration 7):
- **Index access via emitAccessChainCached**: IMPLEMENTED (-34 IDs). Root cause: index_access handler bypassed emitAccessChainCached, allocating new IR IDs for each AccessChain. Even though codegen deduplicates the SPIR-V output, semantic-level load_cache couldn't match different IR IDs.
- **Extract image dedup via emitPureOp**: IMPLEMENTED (-4 IDs). Converted all 4 extract_image sites to emitPureOp. Same sampler always produces same image.
- **Binary op pure_op_cache pre-check**: IMPLEMENTED (-15 IDs). Moved result_id allocation AFTER cache check. Covers all arithmetic ops. Key: no IDs wasted on cache hits.
- **Codegen dref extraction cache**: IMPLEMENTED (-6 IDs). Added codegen_pure_cache for OpCompositeExtract (dref) and OpVectorShuffle (coord shrinking) in shadow sampler codegen handlers. Eliminated 3 composite_extract + 3 vector_shuffle duplicates.
- **Conversion sites to emitPureOp**: REVERTED (no bound change). Converted remaining conversion emission sites but they had no duplicates.
- **ExtInst pure_op_cache pre-check**: TRIED but doesn't help bound. Pre-allocated result_id is wasted on cache hit (net 0 bound effect).
- **Total progress**: 10881 → 9809 (-1072 IDs, -9.9%), 199/199 pass
- **Remaining actionable duplicates**: 489 total. OpLoad 148 (all cross-block/store-inval), OpAccessChain 11 (cross-block), OpBitcast 4, OpCompositeConstruct 4, OpExtInst 3, OpFunctionCall 3.
- **21 SSA-eligible variables** (1 store, 1 load) could be eliminated. Would save ~63 IDs. Requires dead code elimination at codegen or semantic level.
- **200 dead variables** (stored but never loaded). Could potentially eliminate stores and computing expressions.
- **Diminishing returns**: Further optimization requires complex analysis (dominance analysis for cross-block load caching, dead code elimination, constant propagation, SSA construction).

## PHANTOM ID ANALYSIS (58 IDs across 20 shaders):
- Phantom IDs are allocated by the semantic analyzer but never emitted by the codegen
- Root cause: codegen deduplicates AccessChains (access_chain_cache), but the semantic analyzer already allocated IDs for the duplicates
- The semantic-level AccessChain caching (emitAccessChainCached) catches many duplicates, but some slip through because the index_access handler previously bypassed it
- Even after fixing index_access, some AccessChains in the function_call handler and other paths bypass emitAccessChainCached
- Fix options: (a) convert all AccessChain emission to use emitAccessChainCached, (b) implement ID compaction at codegen level
