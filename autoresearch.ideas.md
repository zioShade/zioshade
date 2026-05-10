# Autoresearch Ideas — glslpp SPIR-V Optimization

## STATUS: 485/485 HLSL tests, 213/222 conformance (95.9%), 0 val_fail, 0 leaks ✅✅

## Recent Optimization Passes Added
- **foldConstBranches**: Fold OpBranchConditional with constant boolean conditions to unconditional OpBranch + remove SelectionMerge
- **constFold comparison folding**: Fold OpFOrdEqual/LessThan/GreaterThan etc with constant operands to OpConstantTrue/OpConstantFalse
- **constFold logical op folding**: Fold OpLogicalOr/OpLogicalAnd with boolean constants, including partial folding (true && b = b, x || true = true)
- **constFold LogicalNot**: Fold LogicalNot(true) = false, LogicalNot(false) = true
- **algebraicSimpl x*0=0**: FMul(x, 0.0) = 0.0, IMul(x, 0) = 0
- **algebraicSimpl div/sub identities**: FDiv/SDiv/UDiv by 1, ISub by 0
- **algebraicSimpl bitwise identities**: Or/Xor with 0 = x, And with 0 = 0, Shift by 0 = x
- **algebraicSimpl x-x=0**: FSub(a,a) = 0.0, ISub(a,a) = 0
- **elimUnreachableBlocks**: Forward reachability analysis + OpPhi cleanup after foldConstBranches
- **foldConstCompositeExtract**: Fold extract(const_composite, N) -> Nth component using zero-alloc position tracking
- **simplifyTrivialPhi**: Eliminate OpPhi where all incoming values are identical; runs at 3 pipeline points (after branchMergePhi, after each elimUnreachableBlocks)
- **deadLoopElim Phase 2.5**: Preserve loops whose func-local vars are loaded after merge
- **mergeBlocks Pass 4 fix**: Protect OpLoopMerge merge/continue target labels from empty-predecessor merging
- All optimizations cascade: constFold -> foldSelect -> foldConstBranches -> elimUnreachableBlocks -> simplifyTrivialPhi -> DCE -> mergeBlocks
- Failed attempt: extending foldCompositeExtract with OpConstantComposite via construct_map caused 91 leaks (ArrayList ownership issue)

## Known Issues / Future Work

### deadLoopElim removes loops whose results flow to output via function-local vars — **FIXED**
- **Symptom**: For-loop with texture samples gets entirely eliminated because `sum` is function-local
- **Root cause**: deadLoopElim only checked immediate side effects (stores to non-func-local vars). Stores to function-local vars that later flow to output variables were missed.
- **Fix**: Added Phase 2.5 to deadLoopElim that checks if stored-to func-local vars are loaded after the loop's merge label. If so, the loop is preserved.
- **Prerequisite**: mergeBlocks Pass 4 bug fix (protecting LoopMerge merge/continue target labels)

### Codegen bug: do-while loop missing continue target label — **FIXED**
- **Root cause**: `mergeBlocks` Pass 4 (empty predecessor merging) did not protect labels that are merge/continue targets of OpLoopMerge. When an empty merge block (from a nested loop) preceded the continue block of an outer loop, Pass 4 would merge the two, replacing the continue label and breaking the LoopMerge reference.
- **Fix**: Added merge/continue target labels to the `structured2` protection set in Pass 4 of `mergeBlocks`.
- **Impact**: This fix also unblocks the deadLoopElim Phase 2.5 fix (preserving loops whose func-local vars flow to output).

### HLSL cross-compiler doesn't reconstruct loops
- SPIR-V loops (OpBranch + OpLoopMerge) are emitted as flat gotos/ifs
- Would need loop pattern recognition (while, for, do-while)

### Array of samplers HLSL emission not ideal
- Treated as cbuffer members instead of Texture2D arrays

### findMSB(uint) type mismatch — needs proper fix
- **Symptom**: `findMSB(uint_val)` returns `uint` in our implementation but should return `int` per GLSL spec
- **Root cause**: The semantic analyzer uses `arg_tids.items[0].ty` as `result_ty` for GLSL builtins. For `findMSB(uint)`, result_ty = uint, but GLSL says findMSB always returns int/ivec.
- **Fix needed**: Add special-case in the function call handler to override result_ty for findLSB/findMSB to always be int (or ivecN based on input vector size)
- **Workaround**: Test T350 uses explicit `uint()` cast

### bitfieldReverse unimplemented
- GLSL `bitfieldReverse(x)` → SPIR-V OpBitReverse (opcode 189)
- Need to add to spirv.zig enum, ir.zig tag, semantic.zig handler, codegen.zig, spirv_to_hlsl.zig
- HLSL equivalent: `reversebits()` for uint, `reversebits()` for int

### uaddCarry, usubBorrow unimplemented
- These return structs (carry + result) making them more complex to implement
