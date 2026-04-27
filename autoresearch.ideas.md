# Autoresearch Ideas

## CURRENT STATUS: 197/197 passes — 100% CONFORMANCE 🎉

All 197 valid test files pass lexer → preprocessor → parser → semantic → codegen → spirv-val.

### What was needed for the last +1 (ground.frag/ocean.vert/ground.vert):
The three-way fix required:
1. **Preprocessor integration**: Enable `Preprocessor.process()` in `compileToSPIRV()` so `#if`/`#else`/`#endif` conditions are properly evaluated
2. **PP skip in parseStatement**: Skip preprocessor directive tokens inside function bodies (return empty expr_stmt)
3. **Param write fix**: When `analyzeLValue` encounters a `.param` symbol being written to, create a local `OpVariable`, copy the param value into it, and re-declare the name as `.var_sym` — this prevents `OpStore` to non-pointer parameter IDs

### Future improvements (not needed for conformance but would improve quality):
- **GPA memory leaks**: Multiple memory leaks in semantic.zig (injectBuiltins, overload map) and codegen.zig (emitExtensions)
- **sampler3d as distinct type**: Currently sampler3D maps to sampler2d (same Dim=2D in SPIR-V). Should have its own AST type with Dim=3D for correctness.
- **sampler2dArray as distinct type**: Currently maps to sampler2d (same codegen). Should have Dim=2D + Arrayed=1.
- **Integer sampler inner IDs**: Only isampler2d and usampler2d save inner IDs. Other integer sampler variants may need their inner IDs saved for correct extract_image in edge cases.
- **Performance**: Preprocessor processing adds overhead; could be skipped for files without PP directives.
