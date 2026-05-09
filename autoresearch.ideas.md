# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 213/222 conformance (95.9%), 0 val_fail ✅
## HLSL tests: 145/145 pass, 0 fail, 2 leaked (CRT shader) ✅
## Session: 131→145 HLSL (+14 tests), conformance 213/222 stable

## ⚠️ Test additions are approaching natural coverage limit
## Further HLSL test additions should only cover genuinely NEW functionality.

## Remaining 9 SKIP (error validation tests — not fixable)
These test that the compiler rejects invalid GLSL. Would need error detection/reporting.

## Bugs Found This Session
- texelFetch new_args memory leak (fixed)
- textureGrad not using explicit_lod IR tag (fixed — added image_sample_grad)
- ImageGather not handled in HLSL backend (fixed — added GatherRed emission)
- fwidth HLSL emitted invalid `fwidth()` call instead of `abs(ddx())+abs(ddy())` (fixed)

## Remaining Known Bugs
- CRT shader leaks 5 operand arrays from binary ops (root cause unclear — allocated in analyzeExpression:2502 but not in any function body at Module.deinit time)
- The CRT shader leak investigation showed Module.deinit properly iterates all 3 function bodies (main: 4 ops, curve: 43 ops, mainImage: 212 ops = 259 total) and frees them, but 5 fadd/fsub operand arrays still leak

## Potential Future Work
- Add component-aware GatherRed/Green/Blue/Alpha based on textureGather component arg
- Add textureOffset test (offset texture sampling)
- Add textureProjLod test
- Add matrix inverse (determinant + adjugate) test
- Add atan2/asin/acos test
- Add floatBitsToUint/int bitcast test
- Add outerProduct test
- Fix parser array type memory leak (parser.zig:708 — already fixed in T25.2)
- Build dominator tree for proper cross-block forwarding in constStoreForward
- Fix the CRT shader's 5 operand array leaks (complex — instructions seem to be in function bodies but still leak)
