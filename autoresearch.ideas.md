# Autoresearch Ideas — glslpp

## STATUS: 210/210 spirv-val, 0 mismatches, 0 failures
## Current: 6655 total_bound across 210 shaders (session 20)
## We BEAT spirv-opt -O on ALL 188 comparable shaders (win 182, tie 6, lose 0)

## SESSION 20 CHANGES (-507 IDs from 7162):
1. elimUnusedGlobals: remove global variables never used as pointer operands (-140 IDs)
2. stripDeadDebugInfo: remove dead type names/decorations after variable removal
3. getOpInfo-based ID operand detection: avoid literal false positives (-257 IDs)
4. Fix 'L'/'s' handler bug: was `wi += 1` (skip 1 word) instead of `wi = ie` (skip all remaining words) (-87 IDs)
5. Iterative cascade: run elimUnusedGlobals + DCE + stripDeadDebugInfo cycle 3 times (-18 IDs)
6. getOpInfo OpTypeImage format field fix (0 impact - all formats are 0)
7. dedupFunctionTypes pass (0 savings - 0 real duplicates)
8. Second round of dedup+DCE after cascade (0 savings)

## VERIFICATION (all 0):
- Dead result IDs: 0 across all 210 shaders
- Duplicate pointer types: 0
- Duplicate struct types: 0
- Duplicate array types: 0
- Duplicate function types: 0
- Duplicate decorations: 0
- Dead OpExtInstImport: 0
- Decorations on non-live IDs: 0
- Unreferenced non-safe instructions: 0
- Dead loads from globals: 0
- Extract->construct reorder patterns: 0
- Cross-block duplicate pure ops: 22 (all have intervening stores)

## PROVABLY CONVERGED AT BINARY LEVEL:
- Every result ID (1..bound-1) is used
- No dead types, constants, or variables
- No duplicate types (struct, pointer, array, function all deduped)
- No duplicate decorations
- All debug info for dead IDs stripped
- Beat spirv-opt -O on ALL 188 comparable shaders
- All getOpInfo-using passes verified correct (no similar 'L'/'s' bugs)
- 4th cascade iteration finds nothing

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Cross-block CSE for loads of immutable variables - requires dominance analysis
2. Accumulator pattern detection - codegen-level OpPhi emission
3. Multi-block function inlining - requires complex CFG merging
4. SSA construction / value numbering - requires liveness analysis
5. Partial redundancy elimination (PRE) for cross-block AC hoisting
6. Loop-invariant code motion (LICM) - requires loop analysis
7. Codegen-level int64/uint64 type support (int64.desktop.comp degenerate types)

## KEY BUG FOUND AND FIXED:
- elimUnusedGlobals had `'l', 'L', 's' => { wi += 1; }` which only skipped ONE word
- 'L' (rest-literals) and 's' (string) should consume ALL remaining words: `{ wi = ie; }`
- This caused literal values in OpExecutionMode (LocalSize 1,1,1) and OpSource to be
  incorrectly counted as references to global variables with small IDs
- 39 shaders had dead global variables kept alive by this bug
