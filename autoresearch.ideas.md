# Autoresearch Ideas — glslpp

## STATUS: 211/211 spirv-val, 0 mismatches, 0 failures
## Current: 7387 total_bound across 211 shaders (session 11)
## We BEAT spirv-opt -O on ALL shaders (total: 7387 vs 7751 = -364 IDs, -4.7%)
## We BEAT glslang on ALL comparable shaders (-43%)

## SESSION 11 CHANGES:
- Scatter-store to CompositeConstruct optimization: -24 IDs (vectors)
- Extended scatter-store to arrays: -8 IDs
- AC redundant load extension: 0 IDs (correct but no max-ID impact)
- Total: -32 IDs from 7419 → 7387

## NEXT OPTIMIZATION TARGETS:

### 1. Store-forward through local structs/arrays (~20-30 IDs, MEDIUM effort)
Pattern: OpStore %var %val → OpAccessChain %ac %var idx → OpLoad %result %ac
17 variables across 12 shaders have this pattern (all passing).
Replace: OpLoad after AC with OpCompositeExtract from %val.
Saves: OpVariable + OpStore + N*(OpAccessChain + OpLoad), adds N OpCompositeExtract.
Affected shaders: copy.flatten.vert, lut-promotion.frag, struct-varying.*, etc.
Implementation: new binary pass "storeForwardExtract" in compact_ids.zig.
Must verify: variable has 1 direct store, 0 whole-loads, N member-loads via AC.

### 2. Multi-block function inlining (~50 IDs, VERY HIGH effort)
8 remaining function calls in 2 shaders with loops/switches.

### 3. Extended loop counter to OpPhi (~30 IDs, HIGH effort)
43 function-local vars with multi-store patterns.

## EXHAUSTED APPROACHES (0 IDs):
- All from Session 10 (see prev file)
- AC redundant load: correct, 0 IDs (eliminated loads not at max ID)
- Identity ops, trivial phis, inverse conversions, dup pointer types: all 0
