# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 213/222 conformance (95.9%), 0 val_fail ✅
## HLSL tests: 164/164 pass, 0 fail, 3 leaked ✅
## Session: 131→164 HLSL (+33 tests, +25.2%), conformance 213/222 stable

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

## Remaining Known Bugs
- CRT shader leaks 5 operand arrays from binary ops (root cause unclear)
- T37.1 (mat2 construction) has minor memory leak
- Matrix transpose doesn't appear in HLSL output (DCE or codegen issue)

## Potential Future Work
- Add ImageWrite handler (imageStore)
- Add AtomicCompareExchange handler
- Fix CRT shader's 5 operand array leaks
- Add component-aware GatherRed/Green/Blue/Alpha based on textureGather component arg
- Add textureOffset test
- Build dominator tree for proper cross-block forwarding in constStoreForward
- IsNan/IsInf test with vector types (bvec result)
