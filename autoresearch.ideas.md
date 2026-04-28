# Autoresearch Ideas

## CURRENT STATUS: 197/197 passes — 100% CONFORMANCE 🎉

All 197 valid test files pass lexer → preprocessor → parser → semantic → codegen → spirv-val.

### Quality improvements completed:
- ✅ Error recovery: tolerate_errors flag for production vs test paths
- ✅ Preprocessor hang: __LINE__/__FILE__/__VERSION__ index fix
- ✅ Memory leaks: all leaks fixed across parser/semantic/codegen
- ✅ sampler3D/sampler2DArray: distinct AST types with correct SPIR-V Dim/Arrayed
- ✅ Stack overflow guard: forward-declare named types in ensureType
- ✅ Token paste (##) operator in preprocessor
- ✅ Stringify (#) operator in preprocessor
- ✅ Error diagnostics: line/column tracking + compileToSPIRVWithDiagnostics
- ✅ Differential testing: full Op comparison against glslangValidator
- ✅ Reference failure analysis: 31 shaders categorized (none are glslpp bugs)

### Test results:
- **180/180 unit tests pass** (including stringify + token paste)
- **197/197 conformance** (spirv-val)
- **0 memory leaks**
- **166/197 differential**: both compilers produce valid SPIR-V, 0 normalized matches (expected — different codegen strategies)
- **31/197 reference failures**: all due to glslang strictness or SPIR-V version requirements

### Known areas for future improvement:
- **OpVariable bloat**: We create ~37x more OpVariables than glslang due to eager param-write local var creation. Only create vars for params that are actually written to.
- **Normalized Op matching**: 0/166 matches in differential testing — investigate structural differences (Op ordering, type dedup, etc.)
- **Performance**: Preprocessor processing adds overhead; could be skipped for files without PP directives.
