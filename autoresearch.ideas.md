# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Current: 7156 total_bound across 199 shaders (-7.6% from 7742, -26.4% from 9721, -34.3% from 10881)
## spirv-opt gap: 21 IDs across 5 shaders (18 from multi-block function inlining, 3 from uninit var)

## SESSION 3 FULL ACHIEVEMENTS (7742 → 7156, -586 IDs, -7.6%):
42. Empty predecessor block merging: -1 ID
43. Redundant store elim for Output/Private vars: -26 IDs
44. Algebraic simplification (FAdd+0, FMul*1, etc.): -5 IDs
45. Cross-block entry-store forwarding + Private var DSE: -13 IDs
46. Dead store elimination (function-local vars): -59 IDs
47. Dead loop elimination + AccessChain-safe pointers: -138 IDs
48. Empty passthrough block merging: -8 IDs
49. FoldSelect constant folding + word-position bug fix: -8 IDs
50. SPIR-V struct type dedup: -10 IDs
51. Double negation elimination: -2 IDs
52. Redundant store elimination (within-block): -6 IDs
53. Empty predecessor block merging: -1 ID
54. Extended redundant store elim to Output/Private: -26 IDs
55. Algebraic simplification: -5 IDs
56. Cross-block entry-store forwarding + Private var DSE: -13 IDs
57. Trivial function inlining (void, 0 params, single block): -39 IDs
58. Extended function inlining with ID renaming (params + return values): -128 IDs
59. Empty-body function inlining + persistent substitution map: -23 IDs
60. Iterative inlining with DCE+compact between passes: -56 IDs

## REMAINING spirv-opt GAP (21 IDs across 5 shaders):

### Multi-block function inlining (18 IDs across 4 shaders)
partial-write-preserve.frag (+6), cfg-preserve-parameter.comp (+4),
combined-texture-sampler-shadow.vk.frag (+4), flush_params.frag (+4).
These have SelectionMerge/BranchConditional/OpSwitch — multi-block control flow.
Would need: clone function body, rewrite branch targets to fresh label IDs,
handle OpSelectionMerge/OpLoopMerge, fix up structured control flow.
This is significant compiler engineering at the SPIR-V binary level.

### Uninitialized variable elimination (3 IDs in 1 shader)
loop-dominator-and-switch-default.frag: function-local var loaded but never stored.
Load feeds OpStore to Output. Safe to remove (storing undef = not storing).
FAILED TWICE: Memory corruption from recursive DCE+DSE chain ownership issues.
Would need: separate pass outside deadCodeElim, OR fix ownership in DCE.

## CLOSED GAPS THIS SESSION:
- barriers.comp: trivial function inlining (-11)
- extended-subgroup-types: empty-body inlining (-5)
- read-from-row-major-array.vert: iterative inlining (-7)
- struct.flatten.vert: algebraic simplification
- mix.frag: redundant store elim for Output vars
- torture-loop.comp: cross-block entry-store forwarding
- 8BitAccess.comp: Private var DSE

## THINGS THAT DIDN'T WORK:
- SPIR-V binary CSE: cross-function/dominance violations
- Uninitialized variable elimination: memory corruption (tried twice)
- Extended function inlining without ID renaming: 16 failures from result ID clashes
- Second-pass optimization pipeline: +12 IDs regression from fresh ID allocation
- Copy propagation: 0 copies exist in our output

## PROMISING NEXT STEPS FOR SESSION 4:

### 1. Multi-block function inlining (saves ~18 IDs)
Most complex remaining optimization. Start with simplest case:
functions with 1 SelectionMerge + 2-3 blocks (if-else with no else).
Steps: (a) clone body with fresh IDs for ALL defined IDs (labels, results),
(b) rewrite branch targets, (c) handle OpSelectionMerge/OpLoopMerge,
(d) substitute params, (e) handle return values.

### 2. Uninit var elimination as standalone pass (saves 3 IDs)
Implement OUTSIDE deadCodeElim to avoid ownership issues.
Scan for function-local vars loaded but never stored. Check all loads
feed only OpStore to Output/StorageBuffer. Remove var + loads + stores.

### 3. Dead OpName/OpMemberName removal (cosmetic, no bound savings)
5 dead OpName instructions exist but don't affect bound.

### 4. Beyond spirv-opt parity
We already BEAT spirv-opt on 48 shaders. Could explore:
- Our codegen produces tighter code for many patterns
- spirv-opt's advantage is entirely from function inlining
