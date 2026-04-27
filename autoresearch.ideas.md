# Autoresearch Ideas

## CURRENT STATUS: 196 passes, 0 compile errors, 1 spirv-val failure

### Remaining 1 spirv-val failure:
1. **ground.frag** — No OpEntryPoint. Parser only produces 5 of 8+ top-level nodes (stops after ApplyLighting). Root cause: no preprocessor integration — `#if`/`#else`/`#endif` blocks are not evaluated, causing both branches to be parsed, leading to parser failures. Preprocessor module exists but integration causes regressions (ocean.vert, ground.vert fail due to OpStore on non-pointer).

### Key insights:
- Preprocessor integration (enabling `Preprocessor.process()` in compileToSPIRV) causes 2 regressions: ocean.vert and ground.vert fail with "OpStore type for pointer not a pointer type" — likely because preprocessor changes code structure that triggers existing codegen bugs with inout params
- ground.frag parser only finds 5 functions: saturate, GlobalPSData (block), ComputeFogFactor, ApplyFog, ApplyLighting — missing ApplySpecular, Resolve, and main
- Integer sampler types are fully working now (isampler2D, usampler2D, etc.)
- samplerCubeArrayShadow keyword + Dref handling added and working

### Completed this session:
- Integer sampler types (20+ new AST types) + codegen + semantic support
- samplerCubeArrayShadow keyword + Dref instruction
- Preprocessor integration attempt (reverted due to regressions)
- extract_image now uses sampler type (not image type) to find correct inner image ID
