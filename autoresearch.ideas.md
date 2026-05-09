# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 213/222 conformance (95.9%), 0 val_fail, 0 leaks ✅✅
## HLSL tests: 222/222 pass, 0 fail, 0 leaked ✅✅
## Session: 131→222 HLSL (+91 tests, +69.5%), conformance 213/222 stable, leaks ALL FIXED

## Session Achievements
- Fixed ALL memory leaks: 150→0 conformance leaks, 0 double-frees
- Added 91 new HLSL cross-compilation tests covering: non-square matrices, derivatives, fwidth, nested structs, boolean comparisons, negate, logical not, switch statements, discard, vector swizzle, sampler2D/cube/array/MS/buffer textures, bit shifts, cbuffer bindings, imageStore, vertex position, bitcast (asfloat/asint), ternary select, type conversions, inverse, mix/lerp, texelFetch, outerProduct, constant arrays, function calls, ImageGather, ImageQuerySize, VectorExtractDynamic, GLSL std.450 builtins (clamp, step, smoothstep, reflect, refract, trig, pow/exp/log, sqrt/rsqrt, cross/normalize, floor/ceil/fract, min/max, inverse/determinant), atomic operations, shadow sampler, multiple render targets, sampler arrays
- Implemented OpSwitch in HLSL cross-compiler
- Implemented ShiftLeftLogical/ShiftRightLogical in HLSL cross-compiler
- Verified 100% conformance coverage of testable shader files (224 non-error/non-asm/non-link files, 213 pass, 9 skip=ERROR, 2 skip=empty/error filename)

## Known Issues
- elimUnusedGlobals can be too aggressive with fragment shader output stores
- Array of samplers HLSL emission not ideal (treated as cbuffer)
- HLSL cross-compiler doesn't reconstruct loops (while/for/do-while) from SPIR-V
- Multiple cbuffer bindings all use register(b0)

## Future Directions
- Fix elimUnusedGlobals aggressive optimization on fragment outputs
- Add loop reconstruction in HLSL cross-compiler
- Improve array of samplers HLSL emission
- Fix multiple cbuffer register bindings
- Geometry shader EmitVertex/EndPrimitive → HLSL stream append
- Tessellation shaders (hull/domain)

## Optimizer Bug: elimUnusedGlobals Too Aggressive
- Fragment shaders with `out vec4 fragColor` where the output is stored but never read get their output variable removed by elimUnusedGlobals
- This cascades to remove all instructions that produced the stored value, eventually removing the entire function body
- Reproducible with: `sqrt(x) + rsqrt(x)` stored to fragment output
- Fix needed: Output variables (StorageClass.Output) in fragment shaders should be marked as "externally used" and never removed by elimUnusedGlobals
