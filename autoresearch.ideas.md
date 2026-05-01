# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 187/199 exact matches (94%), 149/149 gap tests, 8/9 Ghostty spirv-val
## Commit: b642f86 (DFE constant rescue + codegen pre-scan)

## CRITICAL BUG FIXED:
- Dead function elimination was silently producing invalid SPIR-V for Ghostty shaders
- Root cause: const_cache in semantic.zig + DFE removing constant definitions
- Fix: Rescue constants from eliminated functions + pre-scan in codegen
- This bug was masked because Ghostty shaders were classified as INVALID in the benchmark
- After fix: 8/9 Ghostty shaders now pass spirv-val (was silently broken before)

## CURRENT METRICS:
- 199/199 spirv-val ✅
- 187/199 exact output store matches (94.0%)
- 7 zero mismatches (ALL vendor extensions)
- 5 structural mismatches (SSA vs memory, functionally equivalent)
- 149/149 gap tests ✅
- 8/9 Ghostty shaders pass spirv-val ✅

## REMAINING GAPS:
- 7 vendor extensions (QCOM, ARM tensor, ray query, nonuniform)
- 5 structural (SSA differences, not bugs)
- cell_text.v.glsl: semantic analysis error (tolerate_errors produces truncated output)

## NEXT PRIORITY:
1. Fix cell_text.v.glsl semantic error (currently silently fails)
2. GPU visual correctness verification
3. Memory leak fix for tolerate_errors path
4. gl_PerVertex block wrapping

## FEATURES COMPLETED THIS AUTORESEARCH SESSION:
- floatBitsToUint/Int/uintBitsToFloat → OpBitcast
- Dead function elimination with constant rescue
- gl_FragDepth + depth execution modes (DepthGreater/Less/Unchanged)
- EarlyFragmentTests execution mode
- 54 gap tests (50 original + 4 depth)
- DFE constant rescue bug fix
- Codegen constant pre-scan
