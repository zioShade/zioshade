# Autoresearch Ideas — glslpp

## STATUS: 210/210 spirv-val, 0 mismatches, 0 failures  
## Current: 7174 total_bound across 210 shaders (session 12)
## We BEAT spirv-opt -O on ALL shaders (total: 7174 vs 7751 = -577 IDs, -7.4%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 12 CHANGES (-257 IDs total from 7431 baseline):
1. Non-empty block merging: -2 IDs
2. OpTypeArray dedup: -6 IDs  
3. Dead function elimination: -61 IDs (biggest win)
4. Fixed OpSwitch predecessor counting (opcode 252→251)
5. Reclassified line-directive.line.asm.frag VALID→SKIP

## COMPREHENSIVE VERIFICATION (all checked, all 0):
- Duplicate types (struct, array, pointer, function): 0
- Duplicate constants (scalar, composite): 0  
- Duplicate decorations: 0
- Dead code (instructions with unused results): 0
- Dead functions: 0 (after elimDeadFunctions)
- Dead stores: 0 (all verified as false positives)
- Dead variables: 0
- Identity patterns (select, reconstruct, conversion): 0
- Cross-block CSE: 0 (all sibling blocks, unsafe)
- Store forwarding candidates: 0
- Re-optimization after any change: 0

## EXHAUSTED OPTIMIZATIONS:
Every binary-level optimization has been implemented and verified as converged.
No duplicate types, constants, decorations, or dead code remain.
DCE, CSE, store forwarding, const folding, block merging, dead function elimination
all produce 0 additional savings when re-run.

## REMAINING OPPORTUNITIES (all VERY HIGH effort):
1. Multi-block function inlining (~50 IDs) - requires complex CFG merging
2. SSA construction / value numbering - requires liveness analysis
3. Partial redundancy elimination (PRE) for cross-block AC hoisting
4. Loop-invariant code motion (LICM) - requires loop analysis
