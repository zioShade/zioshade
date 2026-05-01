# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 9/199 real output mismatches, 9/10 Ghostty shaders
## Commit: e4c3962 (dead function elimination + bitcast builtins)
## All 9 mismatches are vendor extensions NOT needed for wintty
## 145/145 gap tests pass (50 gap tests + 95 existing tests)

## DONE THIS SESSION:
- ✅ 50 gap tests covering all known differences vs glslang (46 pass initially, all 50 now pass)
- ✅ floatBitsToUint/floatBitsToInt/intBitsToFloat/uintBitsToFloat → OpBitcast (was Round via ext_inst)
- ✅ Dead function elimination — BFS reachability from main()
- ✅ Fixed existing vec4 constructor test to accept constant_composite

## REMAINING 9 OUTPUT MISMATCHES (vendor extensions NOT needed for wintty):
- QCOM image processing (4): block-match-sad/ssd, box-filter, sample-weighted
- ARM tensor (3): tensor, tensor_params, tensor_read
- nonuniform-qualifier (1): needs runtime arrays + nonuniformEXT + descriptor indexing
- ray-query (1): needs ray tracing

## FUTURE OPTIMIZATION IDEAS:
- gl_PerVertex block wrapping for canonical vertex shader output
- Function inlining (glslang inlines small functions; our output has more OpFunctionCall)
- GPU visual correctness verification (headless Vulkan renderer)
- Memory leak fix for tolerate_errors path (GPA leaks)
- Performance optimization: avoid linear scan in isConstantId (use a set instead)
- Runtime arrays (OpTypeRuntimeArray) for nonuniform-qualifier shader
- textureGather support
- Reduce extra OpCompositeConstruct for 8-bit type constructors (constant-folding through conversions)

## GAP TEST COVERAGE (145 tests total):
- 95 existing unit tests (lexer, parser, semantic, codegen, preprocessor)
- 50 gap tests (type conversions, texture ops, constant emission, vector ops, matrix ops, bitwise/integer, comparisons, builtins, structural, control flow, data types, Ghostty patterns)
