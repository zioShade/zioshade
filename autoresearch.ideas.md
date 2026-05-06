# Autoresearch Ideas — glslpp

## STATUS: 210/210 spirv-val, 0 mismatches, 0 failures
## Current: 7162 total_bound across 210 shaders (session 16)
## We BEAT spirv-opt -O on ALL shaders (total: 7162 vs 7751 = -589 IDs, -7.6%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 16 CHANGES (ghostty dominance fix):
1. Insert SSA init stores before outermost if's SelectionMerge (if_insert_points stack)
2. Evaluate assign_op RHS before LHS to avoid premature materialization
3. Fix codegen double-free (phi vs bphi_early comparison)
4. Result: all 9/9 ghostty shaders pass spirv-val, 210/210 spirv-cross pass, total_bound=7162

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

## Ghostty Correctness Fixes (Session 15-16)

### Fixed
- mergeBlocks: protect OpSelectionMerge targets from merging (fixes cell_bg.f)
- inlineTrivialFuncs: fix duplicate result IDs when body has ONLY return value as body-defined ID (fixes cell_text.v)
- SSA init store placement: insert before outermost if's SelectionMerge (fixes all ghostty dominance violations)
- assign_op RHS-first evaluation: avoids premature SSA materialization
- codegen double-free fix: phi vs bphi_early comparison

### Status: ALL 9/9 ghostty shaders pass spirv-val

### Root cause (now fixed)
When a local variable is declared with `vec2 tex_coord = expr` and later reassigned
inside a conditional `tex_coord = f(tex_coord)`, the semantic analyzer uses SSA (init_value
used directly). When the reassignment materializes the SSA var inside the conditional,
the OpVariable + initial store were emitted in the conditional block. After moveVarToEntry,
the OpVariable moves to function entry, but the initial store stayed in the conditional block.
If the condition is false, the variable was uninitialized.

Fix: Insert init store before the outermost if's SelectionMerge, and evaluate assignment RHS
before LHS to avoid premature materialization.

