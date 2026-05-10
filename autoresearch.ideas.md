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
- All optimizations cascade: constFold -> foldSelect -> foldConstBranches -> DCE -> mergeBlocks

## Known Issues / Future Work

### deadLoopElim removes loops whose results flow to output via function-local vars
- **Symptom**: For-loop with texture samples gets entirely eliminated because `sum` is function-local
- **Root cause**: deadLoopElim only checks immediate side effects (stores to non-func-local vars). Stores to function-local vars that later flow to output variables are missed.
- **Attempted fix**: Phase 2.5 in deadLoopElim that checks if stored-to func-local vars reach output stores. BLOCKED by torture-loop.comp regression.
- **Blocker**: torture-loop.comp has a codegen bug — do-while loop's continue label (id 27) is never emitted by codegen. The broken loop structure causes spirv-val "forward referenced IDs" when the loop is preserved. Need to fix the codegen bug first.
- **Impact**: Any shader with loops that accumulate into a local variable and store to output after the loop will have the loop body incorrectly eliminated.

### Codegen bug: do-while loop missing continue target label
- **Shader**: tests/spirv-cross/torture-loop.comp (do-while loop)
- **Issue**: OpLoopMerge references continue target id 27, but no OpLabel with id 27 is emitted
- **Current workaround**: deadLoopElim removes the broken loop, hiding the bug

### HLSL cross-compiler doesn't reconstruct loops
- SPIR-V loops (OpBranch + OpLoopMerge) are emitted as flat gotos/ifs
- Would need loop pattern recognition (while, for, do-while)

### Array of samplers HLSL emission not ideal
- Treated as cbuffer members instead of Texture2D arrays
