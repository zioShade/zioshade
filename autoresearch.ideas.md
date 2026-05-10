# Autoresearch Ideas — glslpp SPIR-V Optimization

## STATUS: 460/460 HLSL tests, 213/222 conformance (95.9%), 0 val_fail, 0 leaks ✅✅

## Recent Optimization Passes Added
- **foldConstBranches**: Fold OpBranchConditional with constant boolean conditions to unconditional OpBranch + remove SelectionMerge
- **constFold comparison folding**: Fold OpFOrdEqual/LessThan/GreaterThan etc with constant operands to OpConstantTrue/OpConstantFalse
- **constFold logical op folding**: Fold OpLogicalOr/OpLogicalAnd with boolean constants, including partial folding (true && b = b, x || true = true)
- **constFold LogicalNot**: Fold LogicalNot(true) = false, LogicalNot(false) = true
- **algebraicSimpl x*0=0**: FMul(x, 0.0) = 0.0, IMul(x, 0) = 0
- **algebraicSimpl div/sub identities**: FDiv/SDiv/UDiv by 1, ISub by 0
- **algebraicSimpl bitwise identities**: Or/Xor with 0 = x, And with 0 = 0, Shift by 0 = x
- **elimUnreachableBlocks**: Forward reachability analysis + OpPhi cleanup after foldConstBranches
- **foldConstCompositeExtract**: Fold extract(const_composite, N) -> Nth component using zero-alloc position tracking
- All optimizations cascade: constFold -> foldSelect -> foldConstBranches -> elimUnreachableBlocks -> DCE -> mergeBlocks
- Failed attempt: extending foldCompositeExtract with OpConstantComposite via construct_map caused 91 leaks (ArrayList ownership issue)

## Known Issues / Future Work

### deadLoopElim removes loops whose results flow to output via function-local vars
- **Symptom**: For-loop with texture samples gets entirely eliminated because `sum` is function-local
- **Root cause**: deadLoopElim only checks immediate side effects (stores to non-func-local vars). Stores to function-local vars that later flow to output variables are missed.
- **Attempted fix**: Phase 2.5 in deadLoopElim that checks if stored-to func-local vars are loaded after merge. BLOCKED by nested loop codegen bugs.
- **Blocker**: torture-loop.comp has nested loops with complex structure. The Phase 2.5 fix preserves the `while(++k<10)` loop and nested for-loops because `idat` (func-local) is stored to `out_data` (buffer) after the loops. But preserving these loops triggers codegen bugs (missing continue labels in do-while loops).
- **Impact**: Any shader with loops that accumulate into a local variable and store to output after the loop will have the loop body incorrectly eliminated.
- **Required fix**: First fix codegen to always emit continue labels for do-while loops, then re-apply Phase 2.5.

### Codegen bug: do-while loop missing continue target label — **FIXED**
- **Root cause**: `mergeBlocks` Pass 4 (empty predecessor merging) did not protect labels that are merge/continue targets of OpLoopMerge. When an empty merge block (from a nested loop) preceded the continue block of an outer loop, Pass 4 would merge the two, replacing the continue label and breaking the LoopMerge reference.
- **Fix**: Added merge/continue target labels to the `structured2` protection set in Pass 4 of `mergeBlocks`.
- **Impact**: This fix also unblocks the deadLoopElim Phase 2.5 fix (preserving loops whose func-local vars flow to output).

### HLSL cross-compiler doesn't reconstruct loops
- SPIR-V loops (OpBranch + OpLoopMerge) are emitted as flat gotos/ifs
- Would need loop pattern recognition (while, for, do-while)

### Array of samplers HLSL emission not ideal
- Treated as cbuffer members instead of Texture2D arrays
