# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 213/222 conformance (95.9%), 0 val_fail ✅
## HLSL tests: 168/168 pass, 0 fail, 0 leaked ✅✅
## Session: 131→168 HLSL (+37 tests, +28.2%), conformance 213/222 stable, leaks 3→0

## All Memory Leaks Fixed!
- CRT shader pure_op_cache leak: operands not freed on cache hit (binary ops)
- T37.1 mat2 construction col_ids temp array leak
- texelFetch new_args leak (previous fix)
- emitPureOp cache hit operand leaks (previous fix)

## Genuine Bug Fixes This Session
1. texelFetch new_args memory leak (allocated but never freed)
2. textureGrad missing IR tag (added image_sample_grad)
3. ImageGather HLSL handler (added GatherRed emission)
4. fwidth HLSL wrong emission (expanded to abs(ddx)+abs(ddy))
5. Bitcast HLSL handler (asint/asfloat for float↔int bitcasts)
6. IsNan/IsInf HLSL handlers (isnan/isinf emission)
7. ImageQuerySize/ImageQuerySizeLod HLSL handlers (GetDimensions)
8. UConvert/SConvert/FConvert type conversion handlers
9. ImageRead handler (image[coord] indexing)
10. ImageWrite handler (image[coord] = value)
11. All atomic operation handlers (InterlockedAdd/Min/Max/And/Or/Xor/Exchange/CompareExchange)
12. pure_op_cache operand leak on binary op cache hit
13. mat2 construction col_ids temp array leak

## Remaining Known Issues
- **Matrix local variable column access not emitted**: `mat4 t = transpose(u.m); fragColor = t[0];` — the raw SPIR-V contains OpTranspose but the column extract (t[0]) and output store (fragColor = ...) are NEVER emitted to SPIR-V. The semantic analyzer silently drops the assignment. Root cause: the semantic analyzer creates the transpose result ID but the subsequent statement `fragColor = t[0]` doesn't generate IR. Likely a bug in how mat4-typed local variables are resolved — the variable `t` may not be properly declared as a function-local OpVariable, causing the subscript `t[0]` to fail silently with tolerate_errors=true.
- HLSL variable naming uses fallback "0" for unnamed IDs (quality, not correctness)

## Test Coverage by Feature
- Texture ops: sampler2D, samplerCube, texelFetch, textureGrad, textureGather, textureSize, textureOffset, textureLod, textureProj
- Math: exp/log, sqrt/rsqrt, sin/cos, atan2/asin/acos, mod (floor-based), pow, abs, sign, floor, ceil, fract, trunc, round, min/max, clamp, mix/lerp, step, smoothstep, reflect, refract, determinant, cross, normalize, length, distance, dot
- Derivatives: dFdx/ddx, dFdy/ddy, fwidth
- Bitwise: &, |, ^, <<, >>
- Atomics: InterlockedAdd/Min/Max/And/Or/Xor/Exchange/CompareExchange
- Image: imageLoad, imageStore
- Control flow: if/else, for, while, do-while, break, continue, switch, ternary
- Types: float, int, uint, bool, vec2-4, ivec2-4, uvec2-4, bvec2-4, mat2-4, struct, array
- Conversions: int↔float, bitcast (asint/asfloat)
- Shader stages: fragment, vertex, compute, geometry
- GLSL builtins: equal, notEqual, lessThan, greaterThan, any, all, isnan, isinf

## Genuinely New Features Worth Testing
- sampler2DArray / sampler2DMS (multi-sample textures)
- Subpass input (Vulkan render passes)
- Buffer textures (samplerBuffer)
- Geometry shader EmitVertex/EndPrimitive
- Tessellation shaders
