# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 213/222 conformance (95.9%), 0 val_fail, 0 leaks ✅✅
## HLSL tests: 239/239 pass, 0 fail, 0 leaked ✅✅
## Session: 131→239 HLSL (+108 tests, +82.4%), conformance 213/222 stable, leaks ALL FIXED

## Session Summary
- Started at 131 HLSL tests, now 239 (+82.4%)
- Fixed ALL memory leaks: ~150→0 conformance leaks, 0 double-frees
- Fixed elimUnusedGlobals to preserve Output storage class variables
- Implemented OpSwitch in HLSL cross-compiler
- Implemented ShiftLeftLogical/ShiftRightLogical in HLSL cross-compiler
- Added 108 new HLSL tests covering virtually all GLSL features

## Test Coverage (239 tests)
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
- Other: discard, early_fragment_tests, push constants, multiple render targets, sampler arrays, nested structs, compound assignments, function calls, const variables, dynamic vector indexing, vector shuffle

## Known Issues
- DCE eliminates stores to output variables when intermediate computations are unused (optimizer bug)
- HLSL cross-compiler doesn't reconstruct loops (while/for/do-while) from SPIR-V  
- Multiple cbuffer bindings all use register(b0)
- Array of samplers HLSL emission not ideal (treated as cbuffer)
