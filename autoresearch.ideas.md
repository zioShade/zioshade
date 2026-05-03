# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Current: 7402 total_bound across 199 shaders (-23.9% from 9721, -32.1% from 10881)
## spirv-opt gap: 46 IDs across 8 shaders (43 from function inlining, 3 from uninit var)

## SESSION 3 ACHIEVEMENTS:
42. Empty predecessor block merging: -1 ID
43. Redundant store elim for Output/Private vars: -26 IDs
44. Algebraic simplification (FAdd+0, FMul*1, etc.): -5 IDs
45. Cross-block entry-store forwarding + Private var DSE: -13 IDs

## TOTAL SESSION 3: 7742 → 7402 (-340 IDs, -4.4%)

## REMAINING spirv-opt GAP (46 IDs across 8 shaders):

### Function inlining (43 IDs across 7 shaders)
barriers.comp (+11), partial-write-preserve (+8), read-from-row-major (+7),
extended-subgroup-types (+5), combined-texture-sampler-shadow (+4),
cfg-preserve-parameter (+4), flush_params (+4).
Very complex at SPIR-V binary level. Would need: function body cloning,
parameter substitution, return value handling, variable renaming.

### Uninitialized variable elimination (3 IDs in 1 shader)
loop-dominator-and-switch-default.frag: function-local var loaded but never stored.
Load feeds OpStore to Output. Safe to remove (storing undef = not storing).
FAILED: Memory corruption from recursive DCE+DSE chain ownership issues.
Would need: separate pass outside deadCodeElim, OR fix ownership in DCE.

## CLOSED GAPS THIS SESSION:
- struct.flatten.vert: algebraic simplification (FAdd + vec4(0) → x)
- mix.frag: redundant store elim for Output vars
- torture-loop.comp: cross-block entry-store forwarding
- spv.WorkgroupMemoryExplicitLayout.8BitAccess.comp: Private var DSE

## THINGS THAT DIDN'T WORK (SESSION 3):
- SPIR-V binary CSE: cross-function/dominance violations
- Uninitialized variable elimination: memory corruption
