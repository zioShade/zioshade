# Autoresearch Ideas — glslpp

## STATUS: 211/211 spirv-val, 0 mismatches, 0 failures
## Current: 7419 total_bound across 211 shaders (session 11)
## We BEAT spirv-opt -O on ALL shaders (total: 7419 vs 7751 = -332 IDs, -4.3%)
## We BEAT glslang on ALL comparable shaders (-42%)

## SESSION 11 FINDINGS:
- Extended elimRedundantLoads to handle AccessChain-derived pointers from readonly vars: correct, saves 0 IDs
  - The eliminated loads (5 across all shaders) aren't at the top of the ID space
  - compactIds renumbers by instruction order; only eliminating the LAST instruction reduces bound
- 188/210 shaders have OpLabel as the max ID (entry block label — uneliminable)
- 12 shaders have arithmetic/logic at max ID (essential computations like fract())
- Attempted scatter-store to CompositeConstruct optimization (5 vars across 5 shaders)
  - ocean.vert: var %131 (v4uint, 4 AC-stores + 1 load)
  - block-match-sad/ssd: var %15 (2 AC-stores + 1 load each)
  - insert.comp: var %3 (4 AC-stores + 1 load)
  - return-array.vert: var %29 (2 AC-stores + 1 load)
  - Implementation had memory bugs (double-free in defer blocks), reverted
- Key insight: eliminating instructions in the MIDDLE of the ID space doesn't reduce bound
  - The total_bound = sum of (max_used_id + 1) per shader
  - compactIds renumbers IDs sequentially by instruction position
  - Only the LAST instruction in each shader matters for the bound
- Confirmed all binary-level micro-optimizations are exhausted:
  - Identity ops: 0, Trivial phis: 0, Inverse conversions: 0
  - Duplicate pointer types: 0, Single-use constants: all used

## REMAINING PATHS (all high effort):

### 1. Scatter-store to CompositeConstruct (~20 IDs, HIGH effort)
Binary-level pass that detects function-local vector variables where all components
are stored via AccessChain (scatter stores) and the whole variable is loaded once.
Replace with OpCompositeConstruct, eliminating the variable, AccessChains, and stores.
5 variables across 5 shaders. Complex to implement correctly (memory management issues).

### 2. Multi-block function inlining (~50 IDs, VERY HIGH effort)
8 remaining function calls across 2 shaders. Functions have loops/switches.
Need to: clone body blocks, rename all IDs, patch branch targets,
handle OpLoopMerge/OpSelectionMerge, replace params with args.
Starting point: inlineTrivialFuncs in compact_ids.zig (handles single-block functions).

### 3. Extended loop counter to OpPhi (~30 IDs, HIGH effort)
43 function-local vars remain with multi-store patterns.
Converting more complex loop counters (multiple updates, conditional updates)
to OpPhi would eliminate the variable.
Starting point: loopCounterToPhi in loop_counter_phi.zig.

### 4. Semantic layer: avoid creating SSA vars that become dead
The unssaScope function creates variables for SSA symbols at scope end.
Most are eliminated by DCE, but some survive because the variable is read
after the scope ends. Could potentially skip variable creation if we can
prove no one reads after the scope, but this requires scope-level analysis.

## EXHAUSTED APPROACHES (0 IDs saved):
- All from Session 10 (see below)
- AC redundant load extension: correct but 0 IDs (eliminated IDs not near bound)
- Identity operations: 0 (all handled by algebraicSimpl)
- Trivial phi elimination: 0 (none exist)
- Inverse conversion pairs: 0 (none exist)
- Duplicate pointer types: 0 (already deduplicated)
