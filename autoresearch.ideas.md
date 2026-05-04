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

## CORRECT BUT 0-ID EXTENSIONS (kept for correctness):
- OpCompositeExtract(OpVectorShuffle) folding: correct, 0 instances in benchmark
- Identity VectorShuffle elimination: correct, all Shuffle(v,v,0,1) are swizzles (different dimensions)

## VERIFICATION FINDINGS:
- CSE correctly handles all arithmetic opcodes (verified with debug prints)
- Our spirv.zig uses different opcode numbers than Python's assumed SPIR-V spec mapping
- All "duplicate conversions" found by Python were actually FAdd operations (correct opcode mapping)
- 99 shaders have TypePointer as max ID, 68 have Label, 101 have AccessChain
- All max-ID instructions are genuinely needed (0 dead max-ID ACs, 0 unused types)

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
- Cross-block AC CSE: 6 duplicates in sibling blocks (can't dominate)
- Second pipeline iteration: fully converged
- Multi-store function-local vars: 0 remaining (all optimized)
- Redundant loads: 0 remaining (5 in PhysicalStorageBuffer, unsafe to eliminate)
- Dead decorations: 0
- Unused interface variables: 639 found but all required by SPIR-V entry point interface
- Extract(Shuffle) folding: 0 instances
- Identity VectorShuffle: 0 true identity (all are swizzles)
- No-op conversion chains (SToF→FToS): 0
- Duplicate arithmetic ops (correct opcodes): 0
- Dead max-ID AccessChains: 0
- Unused types: 0
- Mergeable max-ID blocks: 0
- Chained AccessChains: 0

## REMAINING OPPORTUNITIES (all VERY HIGH effort):

### 1. Multi-block function inlining (~50 IDs, VERY HIGH effort)
5 shaders with 16 total function calls. Most have arguments and complex control flow.
shader-debug-info-line-directives.line.gV.frag has 6 calls to 3 leaf functions with loops.

### 2. SSA construction / value numbering (~?? IDs, VERY HIGH effort)
Would enable cross-block copy propagation, redundant computation elimination.
Requires dominator tree, SSA construction infrastructure.

### 3. Dead code elimination at the codegen level (~?? IDs, HIGH effort)
Modify codegen.zig to emit fewer instructions in the first place.
Examples: avoid emitting unused variable declarations, fold constants during codegen.
Requires deep understanding of codegen + semantic analysis interaction.
