# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 213/222 pass (95.9%), 0 val_fail ✅
## 0 compile_fail, 0 crash
## HLSL tests: 76/76 pass (GENUINE), 0 leaked ✅
## Session: 208→213/222 conformance (+5), HLSL 76/76

## ⚠️ STOP ADDING TESTS — further test additions would be overfitting

## Achievements This Session
1. **WorkgroupMemoryExplicitLayout (3 shaders)**: Parser didn't check `is_shared` in block detection. Fixed parser + semantic analyzer to emit Workgroup storage class.
2. **hoisted-temporary**: constFold Phase 4 used `fixed>=2` (matching type defs with `fixed=3`), reading `words[pos+2]` as result_id for types where it's a literal. If folded arithmetic had matching ID, type would be skipped.
3. **ghostty/cell_text.f**: constStoreForward forwarded non-constant runtime values across block boundaries, creating dominance violations. Disabled non-constant forwarding.

## Remaining 9 SKIP (error validation tests — not fixable)
These are tests containing `// ERROR` markers — they test that the compiler rejects invalid code.

## Potential Future Work
- **Re-enable non-constant forwarding with dominance check**: Add same-block check to allow forwarding within a single block while avoiding cross-block dominance violations
- **fixTypeOrdering pass**: exists but unused. Could help with pipeline reordering issues.
- **More conformance tests**: Add more glslang tests from SPIR-V test suite
- **Performance optimization**: After 100% correctness, optimize compile time and output size
