# Autoresearch Ideas — glslpp

## STATUS: 210/210 spirv-val, 0 mismatches, 0 failures
## Current: 7166 total_bound across 210 shaders (session 14)
## We BEAT spirv-opt -O on ALL shaders (total: 7166 vs 7751 = -585 IDs, -7.5%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 14 CHANGES (-3 IDs from 7169):
1. branchMergePhi pass: convert branch-merge variables to OpPhi (fixed-buffer approach)
2. Fixed OpPhi word count formula: 3+2*preds (not 2+2*preds)
3. Fixed OpVariable result_id check: pos+2 not pos+1

## VERIFICATION (all 0):
- Duplicate types, constants, decorations: 0
- Dead code: 0
- Dead functions: 0
- Function-scope variables: 0 (all eliminated by phi conversion + other passes)
- Duplicate AccessChains: 0
- Near-miss phi candidates: 0
- Additional passes after phi conversion: 0 savings

## EXHAUSTED OPTIMIZATIONS:
All binary-level optimizations implemented and verified as converged.
branchMergePhi now works correctly and finds all convertible patterns.
No function-scope variables remain in any shader output.

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Multi-block function inlining (~50 IDs) - requires complex CFG merging
2. SSA construction / value numbering - requires liveness analysis
3. Partial redundancy elimination (PRE) for cross-block AC hoisting
4. Loop-invariant code motion (LICM) - requires loop analysis
5. Codegen-level int64/uint64 type support (would fix int64.desktop.comp degenerate types)
