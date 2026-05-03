# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 0/199 mismatches, 0 failures
## Current: 7415 total_bound across 199 shaders (-23.7% from 9721, -31.9% from 10881)
## spirv-opt gap: ~48 IDs across 10-11 shaders (mostly function inlining)

## SESSION 3 ACHIEVEMENTS:
42. Empty predecessor block merging: -1 ID
43. Redundant store elim for Output/Private vars: -26 IDs
44. Algebraic simplification (FAdd+0, FMul*1, etc.): -5 IDs

## TOTAL SESSION 3: 7742 → 7415 (-327 IDs, -4.2%)

## REMAINING spirv-opt GAP (~48 IDs across 10-11 shaders):

### Function inlining (~37 IDs across 7 shaders)
Biggest gaps: barriers.comp (+11), partial-write-preserve.frag (+8), 
read-from-row-major-array.vert (+7), extended-subgroup-types (+5),
combined-texture-sampler-shadow (+4), cfg-preserve-parameter (+4),
flush_params (+4). Very complex at SPIR-V binary level.

### Non-inlining gaps (~11 IDs across 4 shaders)
- loop-dominator-and-switch-default.frag (+3): uninitialized var whose load feeds OpStore to Output
- struct.flatten.vert: CLOSED by algebraic simplification
- mix.frag: CLOSED by redundant store elim for Output vars
- torture-loop.comp (+1): cross-block store-to-load forwarding
- spv.WorkgroupMemoryExplicitLayout.8BitAccess.comp (+1): dead store to Private var

### Uninitialized variable elimination (+3 IDs in loop-dominator-and-switch-default.frag)
Function-local var loaded but never stored. Load feeds OpStore to Output.
FAILED: Memory corruption from recursive DCE+DSE chain. Would need separate pass
outside deadCodeElim to avoid ownership issues.

### Dead store to Private variables (+1 ID in 8BitAccess.comp)
Private var stored but never loaded. Our dead store elim only handles Function storage.
Extending to Private would need care not to break SSBO/Workgroup vars.

### Cross-block store-to-load forwarding (+1 ID in torture-loop.comp)
Function-local var stored in entry block, loaded in another block.
Our store-to-load forwarding is within-block only. Would need dominance analysis.

## THINGS THAT DIDN'T WORK (SESSION 3):
- SPIR-V binary CSE: 19 failures from cross-function/dominance violations
- Uninitialized variable elimination: memory corruption from recursive DCE+DSE
- Cross-function global_load_cache (7 spirv-val failures) — from session 2
