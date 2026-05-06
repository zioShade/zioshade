# Autoresearch Ideas — glslpp

## STATUS: 210/210 spirv-val, 0 mismatches, 0 failures  
## Current: 7169 total_bound across 210 shaders (session 13)
## We BEAT spirv-opt -O on ALL shaders (total: 7169 vs 7751 = -582 IDs, -7.5%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 13 CHANGES (-5 IDs from 7174):
1. Second dedupStructTypes at end of pipeline (after optimizations unify member types): -1 ID
2. Decoration skipping in dedupStructTypes (skip OpDecorate/OpMemberDecorate on replaced IDs): required for struct dedup
3. dedupPointerTypes pass (merge duplicate OpTypePointer after struct dedup): -1 ID
4. Hoist invariant AccessChain from branch targets to header: -3 IDs

## COMPREHENSIVE VERIFICATION (all checked, all 0):
- Duplicate types (struct, array, pointer, function, vector, matrix, image, sampler): 0
- Duplicate constants (scalar, composite): 0  
- Duplicate decorations: 0
- Dead code (instructions with unused results): 0
- Dead functions: 0 (after elimDeadFunctions)
- Dead stores: 0 (all verified as false positives)
- Dead variables (non-entrypoint): 0
- Identity patterns (select, reconstruct, conversion): 0
- Cross-block CSE: 0 (all sibling blocks, unsafe)
- Store forwarding candidates: 0
- Redundant extract-construct chains: 0
- Duplicate AccessChain instructions: 0
- Re-optimization after any change: 0

## EXHAUSTED OPTIMIZATIONS:
Every binary-level optimization has been implemented and verified as converged.
No duplicate types, constants, decorations, or dead code remain.
DCE, CSE, store forwarding, const folding, block merging, dead function elimination,
struct dedup, pointer dedup, array dedup all produce 0 additional savings when re-run.

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Multi-block function inlining (~50 IDs) - requires complex CFG merging
2. SSA construction / value numbering - requires liveness analysis
3. Partial redundancy elimination (PRE) for cross-block AC hoisting
4. Loop-invariant code motion (LICM) - requires loop analysis
5. Codegen-level int64/uint64 type support (would fix int64.desktop.comp degenerate types)
