# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 213/222 conformance (95.9%), 0 val_fail, 0 leaks ✅✅
## HLSL tests: 245/245 pass, 0 fail, 0 leaked ✅✅
## Session: 131→245 HLSL (+114 tests, +87.0%), conformance 213/222 stable, leaks ALL FIXED

## Session Summary
- Started at 131 HLSL tests, now 245 (+87.0%)
- Fixed ALL memory leaks: ~150→0 conformance leaks, 0 double-frees
- Fixed elimUnusedGlobals to preserve Output storage class variables
- Fixed binding_shift=-1 bug (all cbuffers used register(b0))
- Fixed cbuffer member name collision (multi-cbuffer member access)
- Implemented OpSwitch, ShiftLeftLogical/ShiftRightLogical in HLSL cross-compiler
- Implemented OpCopyMemory, OpCopyObject, OpPhi in HLSL cross-compiler
- Added OpCopyMemory=63, OpCopyObject=83, OpPhi=245 to spirv.zig Op enum
- Added 114 new HLSL tests covering virtually all GLSL features

## Test Coverage (245 tests)
- Texture ops: sampler2D, samplerCube, sampler2DArray, sampler2DMS, samplerBuffer, isampler2D, usampler2D, sampler2DShadow, textureLod, textureGrad, textureGather, texelFetch, texelFetchOffset, textureOffset, textureSize, textureProj
- Math builtins: sin/cos/tan, asin/acos/atan2, pow/exp/log/exp2/log2, sqrt/rsqrt, floor/ceil/fract/abs/sign, min/max/clamp, mix/lerp/step/smoothstep, reflect/refract/faceforward, cross/normalize/length/distance, determinant/inverse/outerProduct, round/roundEven, mod, fma
- Derivatives: dFdx/ddx, dFdy/ddy, fwidth, dFdxCoarse/dFdxFine
- Bitwise: &, |, ^, <<, >>
- Atomics: InterlockedAdd/Min/Max/And/Or/Xor/Exchange/CompareExchange
- Image: imageLoad/imageStore
- Control flow: if/else, for, while, do-while, break, continue, switch, ternary
- Types: float, int, uint, bool, vec2-4, ivec2-4, uvec2-4, bvec2-4, mat2-4, mat2x3/mat3x2 (non-square), struct, array
- Conversions: int↔float, bitcast (asint/asfloat), ConvertSToF/ConvertFToS
- Shader stages: fragment, vertex, compute, geometry
- GLSL builtins: equal, notEqual, lessThan, greaterThan, any, all, isnan, isinf, gl_FragCoord, gl_Position, gl_FrontFacing, gl_Layer
- HLSL backend features: OpCopyObject, OpCopyMemory, OpPhi, cbuffer prefix naming
- Other: discard, early_fragment_tests, push constants, multiple render targets, sampler arrays, nested structs, compound assignments, function calls, const variables, dynamic vector indexing, vector shuffle

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
