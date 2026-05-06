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

## Ghostty Correctness Fixes (Session 15)

### Fixed
- mergeBlocks: protect OpSelectionMerge targets from merging (fixes cell_bg.f)
- inlineTrivialFuncs: fix duplicate result IDs when body has ONLY return value as body-defined ID (fixes cell_text.v)

### Remaining (dominance violations)
- bg_image.f: tex_coord computed in header, reassigned inside if-then, used after merge
- cell_text.f: similar pattern - value from conditional used after merge

### Root cause
When a local variable is declared with `vec2 tex_coord = expr` and later reassigned
inside a conditional `tex_coord = f(tex_coord)`, the semantic analyzer uses SSA (init_value
used directly). When the reassignment materializes the SSA var inside the conditional,
the OpVariable + initial store are emitted in the conditional block. After moveVarToEntry,
the OpVariable moves to function entry, but the initial store stays in the conditional block.
If the condition is false, the variable is uninitialized.

### Attempted fixes
1. **unssaAllScopes before if_stmt**: Materializes all SSA vars before the if. Works for
   210/210 spirv-cross tests but causes double-free and missing OpVariables in ghostty shaders.
   The optimization pipeline removes the OpVariable from the final output.
2. **global_load_cache forwarding**: Cache init_value in global_load_cache so cross-block loads
   get the init_value directly. Causes 3 regressions in spirv-cross tests (loop-related
   dominance issues).

### Correct fix approach
Need to either:
1. Emit the initial store BEFORE the if statement (requires splitting materialization into
   "declare variable at current point" and "store initial value at an earlier point")
2. Use OpPhi at the merge block instead of OpVariable (requires phi support in codegen)
3. Track SSA vars that are reassigned inside conditionals and eagerly materialize them
   at the declaration point (before any conditional)
