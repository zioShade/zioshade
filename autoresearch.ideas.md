# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Current: 7743 total_bound across 199 shaders (-20.3% from 9721, -28.8% from 10881)
## 4 IDs BETTER than spirv-opt --compact-ids + all aggressive passes!

## THIS SESSION ACHIEVEMENTS:
30. Comparison operator dedup via pure_op_cache (-2 IDs)
31. Constant folding in type constructor (-21 IDs)
32. AccessChain merging: single-use intermediates (-98 IDs)
33. Global load cache for all blocks (-1 ID)
34. Multi-use AC merge: bases used only by other ACs (-10 IDs)

## TOTAL THIS SESSION: 7873 → 7743 (-130 IDs, -1.7%)

## REMAINING WASTE: 199 IDs (1 per shader, pre-allocation — minimum)

## FUTURE OPTIMIZATION OPPORTUNITIES (requires architectural changes):

### Cross-function Input/Uniform load sharing (~30 IDs)
FAILED: Preserving global_load_cache across functions causes dominance violations.
SPIR-V prohibits using IDs defined in one function in another function.
Would need: pass loaded values as function parameters, or inline functions.

### Cross-block load/AC hoisting (~46 loads + 9 ACs)
Cross-block duplicates exist because blocks don't dominate each other (if-else branches).
Would need: speculative load/AC emission in entry block (two-pass analysis).
1. First pass: identify which global variables/ACs are loaded in multiple branches
2. Second pass: emit loads/ACs in entry block, use results in all branches

### Dead loop/branch elimination (~29 IDs in 1 shader)
spirv-opt eliminates entire loops that have no observable side effects.
inside-loop-dominated-variable-preservation.frag: spirv-opt reduces 53→24 IDs.
Would need: control flow analysis to detect dead loops.

### Dead code: !!b optimization (~3 IDs in 1 shader)
unary-enclose.frag: `b = false; !!b` could be simplified to just `b = false`.
Would need: constant propagation through logical not chains.

### Composite construct array handling (~13 IDs in 1 shader)
composite-construct.comp: multi-dimensional array construction not optimal.
Would need: better array copy/multi-dim constructor optimization.

## THINGS THAT DIDN'T WORK:
- Cross-function global_load_cache preservation (7 spirv-val failures)
- Cross-block AC caching from all blocks (dominance violations)
- Binary op constant folding (all conversions are runtime values)
- Iterative merge+DCE loop (no additional savings)
