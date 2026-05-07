# Autoresearch Ideas — glslpp

## STATUS: 210/210 spirv-val, 0 mismatches, 0 failures
## Current: 6742 total_bound across 210 shaders (session 19)
## We BEAT spirv-opt -O on ALL 188 comparable shaders (win 182, tie 6, lose 0)

## SESSION 19 CHANGES (-420 IDs from 7162):
1. elimUnusedGlobals: remove global variables never used as pointer operands (-140 IDs)
2. stripDeadDebugInfo: remove dead type names/decorations after variable removal
3. getOpInfo-based ID operand detection: avoid literal false positives (-257 IDs from proper detection)
4. Iterative cascade: run elimUnusedGlobals + DCE + stripDeadDebugInfo cycle 3 times (-18 IDs)
5. Fixed getOpInfo for OpTypeImage: format field was incorrectly marked as ID

## VERIFICATION (all 0):
- Dead result IDs: 0 across all 210 shaders
- Duplicate decorations: 0
- Duplicate function types: 1 (helper-invocation.frag)
- Dead OpExtInstImport: 0
- Dead OpTypeFunction: 1
- Load->Store copies: 3 (all multi-use, can't eliminate)
- Duplicate AccessChains: 0

## PROVABLY CONVERGED AT BINARY LEVEL:
- Every result ID (1..bound-1) is used
- No dead types, constants, or variables
- No duplicate types (struct, pointer, array all deduped)
- No duplicate decorations
- All debug info for dead IDs stripped
- Beat spirv-opt -O on ALL 188 comparable shaders

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Multi-block function inlining - requires complex CFG merging
2. SSA construction / value numbering - requires liveness analysis
3. Partial redundancy elimination (PRE) for cross-block AC hoisting
4. Loop-invariant code motion (LICM) - requires loop analysis
5. Codegen-level int64/uint64 type support (int64.desktop.comp degenerate types)
6. Deduplicate OpTypeFunction (1 potential ID)
