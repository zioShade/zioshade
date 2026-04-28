# Autoresearch Ideas

## CURRENT STATUS: 197/197 passes — 100% CONFORMANCE 🎉

All 197 valid test files pass lexer → preprocessor → parser → semantic → codegen → spirv-val.

### Quality improvements completed:
- ✅ Error recovery: tolerate_errors flag for production vs test paths
- ✅ Preprocessor hang: __LINE__/__FILE__/__VERSION__ index fix
- ✅ Memory leaks: all 38 leaks fixed across parser/semantic/codegen
- ✅ sampler3D/sampler2DArray: distinct AST types with correct SPIR-V Dim/Arrayed
- ✅ Stack overflow guard: forward-declare named types in ensureType
- ✅ Token paste (##) operator in preprocessor
- ✅ Error diagnostics: line/column tracking + compileToSPIRVWithDiagnostics
- ✅ Differential testing script against glslangValidator

### Remaining:
- **Stringify (#) operator**: Test fails — the #x in macro body is tokenized
  correctly as .hash + .identifier but substituteAndExpand doesn't produce a
  string_literal. Needs deeper debugging of the PP expansion path.
- **Differential testing**: diff_test.sh counts matches but doesn't diff
  normalized Op sequences yet.
- **Performance**: Preprocessor processing adds overhead; could be skipped
  for files without PP directives.
