# Autoresearch Ideas

## CURRENT STATUS: 196 passes, 0 compile errors, 1 spirv-val failure

### Remaining 1 spirv-val failure:
1. **ground.frag** — No OpEntryPoint. Parser only produces 5 of 8+ top-level nodes (stops after ApplyLighting with GPA crash). Root cause: no preprocessor integration — `#if`/`#else`/`#endif` blocks not evaluated, causing both branches to be parsed. The parser crashes during parseFunctionDecl after ApplyLighting, losing ApplySpecular, Resolve, and main.

### Ideas for future work:
- **Preprocessor integration**: Enable `Preprocessor.process()` but fix the regressions it causes (ocean.vert, ground.vert — OpStore on non-pointer due to changed code structure). The preprocessor works correctly but exposes existing codegen bugs.
- **Fix ground.frag parser crash**: Debug why parseFunctionDecl crashes after ApplyLighting. Likely infinite loop from duplicate code in #if/#else blocks.
- **Fix OpStore on non-pointer**: The `inout` parameter handling creates local variables with OpStore, but in some cases a loaded value (not pointer) is passed. This is exposed by preprocessor changes.
- **More texture builtins**: textureProjOffset is not in isImageSampleBuiltin list — added but check for completeness.
- **sampler3d as distinct type**: Currently sampler3D maps to sampler2d (same Dim=2D in SPIR-V). Should have its own AST type with Dim=3D.
- **sampler2dArray as distinct type**: Currently maps to sampler2d (same codegen). Should have Dim=2D + Arrayed=1.
- **Integer sampler inner IDs**: Only isampler2d and usampler2d save inner IDs. Other integer sampler variants (isampler3d, isampler_cube, etc.) need their inner IDs saved for correct extract_image.
- **GPA memory leaks**: Multiple memory leaks in semantic.zig (injectBuiltins, overload map) and codegen.zig (emitExtensions). Not affecting correctness but causes GPA error output.
- **Stack overflow in runner**: The runner crashes with stack overflow when processing all files at once. Works fine when processing one file at a time (which is what autoresearch.sh does).

### Completed this session:
- Integer sampler types (20+ new AST types) + codegen + semantic support
- samplerCubeArrayShadow keyword + Dref instruction
- Preprocessor integration attempt (reverted due to regressions)
- extract_image now uses sampler type to find correct inner image ID
- Total: 195→196 passes (+1)
