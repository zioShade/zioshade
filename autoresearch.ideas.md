# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Current: 7742 total_bound across 199 shaders (-20.4% from 9721, -28.8% from 10881)
## 4 IDs BETTER than spirv-opt --compact-ids + all aggressive passes!

## THIS SESSION ACHIEVEMENTS:
30. Comparison operator dedup via pure_op_cache (-2 IDs)
31. Constant folding in type constructor (-21 IDs)
32. AccessChain merging: single-use intermediates (-98 IDs)
33. Global load cache for all blocks (-1 ID)
34. Multi-use AC merge: bases used only by other ACs (-10 IDs)
35. Layout-based constCompositeKey for struct dedup (-1 ID)

## TOTAL THIS SESSION: 7873 → 7742 (-131 IDs, -1.7%)

## REMAINING OPPORTUNITIES (all require significant work):

### Dead loop/branch elimination (~29 IDs in 1 shader)
spirv-opt eliminates entire loops with no side effects.
inside-loop-dominated-variable-preservation.frag: 53→24 IDs with spirv-opt.

### Dead code: constant propagation (~3 IDs)
unary-enclose.frag: `b = false; !!b` could simplify to `b = false`.

### Composite construct array handling (~13 IDs)
composite-construct.comp: multi-dim array construction not optimal.

### Cross-function Input/Uniform load sharing
FAILED: Preserving global_load_cache across functions → dominance violations.
Would need: pass loaded values as function parameters.

### Cross-block load/AC hoisting
Would need: speculative load/AC emission in entry block (two-pass analysis).
46 cross-block load dups + 9 cross-block AC dups remain.

### Empty struct type dedup in codegen (~10 IDs)
10 duplicate OpTypeStruct (all empty) across 3 shaders.
emitted_struct_layouts dedup should catch them but doesn't — needs investigation.

## THINGS THAT DIDN'T WORK:
- Cross-function global_load_cache (7 spirv-val failures)
- Cross-block AC caching from all blocks (dominance violations)
- Iterative merge+DCE loop (no additional savings)
- Binary op constant folding (all conversions are runtime values)
- OpCopyObject elimination (misidentified opcode — was OpCompositeExtract)

## THINGS THAT DIDN'T WORK THIS SESSION (continued):
- Dead loop elimination: attempted but buggy. Need data flow analysis to detect
  values that escape the loop via SSA results (not just direct loads).
  cfg.comp: loop loads var in continue block, uses loaded value after merge.
  Also found opcode bug: LoopMerge=246 (not 254), Branch=249 (not 250).
  Two bugs fixed but core algorithm needs escaping value detection.
