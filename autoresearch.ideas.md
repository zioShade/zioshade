# Autoresearch Ideas — glslpp

## STATUS: 210/211 spirv-val, 0 mismatches, 0 failures  
## Current: 7346 total_bound across 211 shaders (session 11)
## We BEAT spirv-opt -O on ALL shaders (total: 7346 vs 7751 = -405 IDs, -5.2%)
## We BEAT glslang on ALL comparable shaders (-45%)

## SESSION 11 CHANGES (-73 IDs total):
1. Scatter-store to CompositeConstruct (vectors): -24 IDs
2. Extended scatter-store to arrays: -8 IDs
3. Store-forward extract (single-index AC): -38 IDs
4. Trivial entry point elimination: -3 IDs

## EXHAUSTED OPTIMIZATIONS (all 0 IDs):
- Type dedup (all types): 298 duplicates at low IDs
- Identity arithmetic (x+0, x*1): 0 instances
- Same-operand comparisons: 0 instances
- Copy propagation for non-constant stores: 0 candidates
- Multi-index store-forward extract: only 2 IDs potential
- Dead function-local vars: 9 truly dead (all at low IDs)
- Duplicate constants: 0 (compactIds handles)
- OpCopyObject elimination: 0 savings
- Extended block merging: 0 (all protected or end with OpReturn)
- Strength reduction (FMul(x,2.0)): only 2 instances, unsafe (NaN)
- Trivial/same-value OpPhi: 0 instances
- AC chains (nested AC): 0 instances
- Cross-block AC CSE: duplicates in sibling blocks
- Second pipeline iteration: fully converged

## REMAINING OPPORTUNITIES (all HIGH effort):

### 1. Multi-block function inlining (~50 IDs, VERY HIGH effort)
5 shaders with 16 total function calls. Most have arguments and complex control flow.
shader-debug-info-line-directives.line.gV.frag has 6 calls to 3 leaf functions with loops.

### 2. Extended loop counter to OpPhi (~30 IDs, HIGH effort)
43 function-local vars with multi-store patterns.

### 3. Helper-invocation pattern (~3 IDs, MEDIUM effort)
main() calls foo(), stores result to output, returns void.
Would require changing callee's return type and appending store.
Fragile — only 1 shader affected.
