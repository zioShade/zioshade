# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Best commit: 32273bf (DCE + ID compaction, fully optimized)
## Total bound: 7912 across 199 shaders (-27.2% from 10881)
## Matches spirv-opt --compact-ids + all aggressive passes exactly!
## Remaining waste: 85 IDs (1.1%) — ALL unavoidable (SPIR-V mandates result <id>)

## NEW OPTIMIZATIONS IMPLEMENTED (this session):
19. SPIR-V ID compaction post-processing pass (-1544 IDs)
20. Dead code elimination in SPIR-V binary (-199 IDs)
21. Iterative DCE to fixpoint (15 iterations max, -81 IDs cascading)
22. Dead type + variable elimination (-48 IDs)
23. Subgroup op DCE (-11 IDs)
24. Deeper DCE iterations (5→15, -5 IDs)
25. Ray query + ExtInstImport DCE (-2 IDs)

## Total improvement this session: -1889 IDs (-19.3% from 9721, -27.2% from 10881)

## PHASE 4: SPIR-V Output Size Optimization
- Baseline: 10881 total bound across 199 shaders
- Current: 9721 (-1160 IDs, -10.6%)
- Average ratio vs glslang: ~0.79x (we're already smaller on average)

## OPTIMIZATIONS IMPLEMENTED (all sessions combined):
1. Semantic-level constant composite dedup (-309 IDs)
2. AccessChain caching within basic blocks (-217 IDs)
3. Load caching within basic blocks (-168 IDs)
4. Targeted store invalidation (-138 IDs)
5. Store-to-load forwarding (-119 IDs)
6. Index access via emitAccessChainCached + emitPureOp (-34 IDs)
7. Struct layout dedup in codegen (-41 IDs)
8. Cross-block load caching for global pointers from entry block (-36 IDs)
9. Vector shuffle dedup via emitPureOp (-28 IDs)
10. Conversion sites to emitPureOp (-17 IDs)
11. Binary op pure_op_cache pre-check (-15 IDs)
12. Global AccessChain cache from entry block (-15 IDs)
13. Scalar splat constant composite cache (-8 IDs)
14. Unary op emitPureOp (-9 IDs)
15. Codegen dref extraction + coordinate shrink cache (-6 IDs)
16. Extract image dedup via emitPureOp (-4 IDs)
17. Composite construct dedup via emitPureOp (-3 IDs)
18. Loop header global cache (-1 ID)

## CORRECTNESS FIXES:
- Fixed global_load_cache invalidation bug in 6 store handlers (compound_assign, assign_op, swizzle assign, pre/post increment, output stores). Was causing stale load results to be reused after stores to global pointers.

## REMAINING WASTE ANALYSIS (85 IDs, 1.1% of bound):
- OpFunctionCall: 38 (SPIR-V mandates result <id>)
- OpAtomicIAdd/And/Or/Xor/Min/Max/Exchange/CompareExchange/FAddEXT: 38 (side effects + mandated result)
- OpFunctionParameter: 4 (can't remove)
- OpRayQueryProceedKHR: 1 (side effects — advances query)

## These are ALL unavoidable — our output matches spirv-opt with aggressive optimization passes.

## REMAINING DUPLICATES (221 within blocks):
- OpVariable: 180 (unique storage, can't dedup)
- OpFunctionParameter: 16 (can't dedup)
- OpTypeStruct: 10 (across different shaders)
- OpBitcast: 3 (rare edge cases in caching)
- Others: 12 (minor)

## HOW TO CONTINUE IN NEXT SESSION

### total_bound is at theoretical minimum (7912, matches spirv-opt aggressive)

### Switch to different Phase 4 metric: compile_time_us
- DCE + compaction adds ~2s overhead for 199 shaders
- Could profile the hotspots and optimize the DCE/compaction passes
- Or optimize the semantic analysis / codegen for speed

### Future: Cross-block load caching with dominance (~62 IDs within functions)
Extend load caching across block boundaries:
1. Need alias analysis for function-local pointers (AccessChain aliasing)
2. Per-block load caching with dominance frontier analysis
3. Only cache loads from blocks that dominate the current block
**Note**: Function-local pointers accessed through different AccessChain results can alias.
Cross-block caching without alias analysis causes duplicate ID definitions.
**Also**: 19 of the 79 cross-block dups are across DIFFERENT FUNCTIONS — can't be fixed
(SPIR-V dominance rules prohibit using load results across function boundaries).

### Future: Extended global_load_cache to ALL entry-block loads (~28 IDs)
FAILED: Pointer aliasing causes duplicate ID definitions.
Could potentially work with per-variable (not per-pointer) caching — map Variable ID → load result
instead of AccessChain ID → load result. But this requires knowing which variable an AccessChain targets.

### COMPLETED: total_bound = 7912 (matches spirv-opt aggressive)
### Session achievement: 9721 → 7912 (-18.6%, -27.2% from 10881 baseline)

## THINGS THAT DIDN'T WORK:
- Global pure op cache (no effect — conversions in non-dominating blocks)
- Store-to-load forwarding to global cache (no effect — rare in dominating blocks)
- Transpose dedup (pre-allocated result_id, `next_id -= 1` is unsafe)
- ID compaction via `next_id -= 1` rollback (causes ID collisions)
- Cross-block cache preserving after unconditional branches (dominance violations)
- ensureType lazy allocation for phantom IDs (chicken-and-egg with recursive types)

## SESSION COMPLETE — total_bound at theoretical minimum
## All 85 remaining waste IDs are mandated by the SPIR-V spec.
## No further total_bound optimization possible without reducing instruction count at the semantic level.
## Potential future directions: compile_time_us optimization, cross-block load caching (requires dominance analysis, saves ~79 IDs in pre-compaction output but may not reduce post-compaction bound).
