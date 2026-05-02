# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Best commit: 26b3969 (DCE + ID compaction)
## Total bound: 8059 across 199 shaders (-25.9% from 10881)
## After spirv-opt --compact-ids: also 8059 (we match!)

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

## REMAINING WASTE ANALYSIS (488 IDs, 5.0% of bound):
- OpLabel: 276 (unreferenced labels from dead blocks)
- OpFunctionCall: 43 (unused results from void-context calls)
- OpLoad: 39 (loads feeding dead stores)
- OpConstant: 29 (constants defined but never referenced in output)
- OpConstantComposite: 16 (composite constants never referenced)
- OpAtomicIAdd/And/Or/Xor: 26 (atomic return values discarded)
- OpBitcast: 8 (unused conversion results)
- Other: 51

## REMAINING DUPLICATES (426 total):
- OpVariable: 208 (can't dedup — each is unique storage)
- OpLoad: 92 (ALL cross-block — need dominance analysis)
- OpFunctionParameter: 45 (can't dedup)
- OpFunction: 40 (can't dedup)
- OpAccessChain: 11 (cross-block)
- OpBitcast: 4 (pre-allocated result_id)
- OpExtInst: 3 (pre-allocated result_id)
- OpFunctionCall: 3 (side effects, can't dedup)
- OpConvertSToF: 3 (cross-block, in switch cases)
- Other arithmetic: ~14 (all cross-block)

## HOW TO CONTINUE IN NEXT SESSION

### Option A: ID Compaction Pass (highest potential, ~488 IDs)
Implement a post-processing pass that remaps SPIR-V IDs to eliminate gaps:
1. Parse the SPIR-V binary instruction by instruction
2. Collect all defined IDs and all referenced IDs
3. Build compact mapping: old_id → new_id (sequential, no gaps)
4. Rewrite all ID references using the mapping
5. Update the Bound header field

**Requires**: Complete opcode ID-position table (knowing which words are IDs vs literals for each of ~140 opcodes). Can be built from the SPIR-V spec grammar.

**Risk**: Getting ID positions wrong corrupts the binary. Validate with spirv-val after compaction.

**Implementation**: Best done as a Python post-processing script that modifies the binary after codegen. Keep it separate from the Zig code.

### Option B: Dead Constant Elimination (~45 IDs)
Fix the reverted dead constant elimination:
1. The scan must also check type references (OpTypeArray references a constant for array size)
2. Need to track which constants are used by `ensureType` calls
3. Alternative: two-pass codegen — first pass emits everything, second pass removes dead constants

### Option C: Cross-Block Load Caching with Dominance (~92 IDs)
Extend load caching across block boundaries using structured dominance:
1. Track which blocks are headers (if/else headers, loop headers)
2. Per-block load caching with dominance frontier analysis
3. Only cache loads from blocks that dominate the current block
4. Requires tracking the control flow graph during semantic analysis

### Option D: Dead Store + Load Elimination (~82 IDs)
Multi-pass dead code elimination:
1. Identify variables that are stored but never loaded (200 dead variables)
2. Remove stores to dead variables
3. Remove loads that only feed dead stores (39 unused loads)
4. Remove computations that only feed dead stores/loads
5. This is a backward dataflow analysis

### Option E: Simpler micro-optimizations
- Eliminate unused OpFunctionCall result IDs (43 IDs) — for void-context calls, don't allocate result_id
- Skip dead label IDs (276 IDs) — requires restructuring block emission to not allocate labels for dead blocks
- Atomic operation result optimization (26 IDs) — don't allocate result_id for atomic ops in statement context

## THINGS THAT DIDN'T WORK:
- Global pure op cache (no effect — conversions in non-dominating blocks)
- Store-to-load forwarding to global cache (no effect — rare in dominating blocks)
- Transpose dedup (pre-allocated result_id, `next_id -= 1` is unsafe)
- ID compaction via `next_id -= 1` rollback (causes ID collisions)
- Cross-block cache preserving after unconditional branches (dominance violations)
- ensureType lazy allocation for phantom IDs (chicken-and-egg with recursive types)
