# Autoresearch Ideas

## CURRENT STATUS: 196 passes, 0 compile errors, 1 spirv-val failure (99.5% conformance)

### Remaining 1 spirv-val failure:
1. **ground.frag** — No OpEntryPoint. Parser only produces 5 of 8+ top-level nodes (stops after ApplyLighting). Root cause: no preprocessor `#if` condition evaluation. Both branches are parsed, parser encounters `pp_if` inside function body, fails, and `synchronize()` skips to `}`, losing the rest of the file.

### Key blocker:
- Preprocessor integration (enabling `Preprocessor.process()`) correctly evaluates `#if` conditions BUT exposes existing codegen bugs: OpStore on non-pointer in ocean.vert/ground.vert
- The codegen bug: when `inout` params are used in functions that have different code paths due to `#if` evaluation, the OpStore target is a loaded value instead of a pointer
- This is a combined preprocessor + codegen fix that needs both pieces working together

### Ideas for future work:
- **Fix OpStore on non-pointer first**: Debug why `inout` param handling creates non-pointer OpStore targets. Fix this codegen bug, THEN enable preprocessor integration.
- **Preprocessor integration**: Enable `Preprocessor.process()` after fixing the codegen bug.
- **PP skip in parseStatement**: Alternative to full PP integration — skip PP lines as no-op statements inside function bodies. This makes the parser find all functions but both branches are parsed.
- **sampler3d as distinct type**: Currently sampler3D maps to sampler2d (same Dim=2D in SPIR-V). Should have its own AST type with Dim=3D.
- **sampler2dArray as distinct type**: Currently maps to sampler2d (same codegen). Should have Dim=2D + Arrayed=1.
- **Integer sampler inner IDs**: Only isampler2d and usampler2d save inner IDs. Other integer sampler variants (isampler3d, isampler_cube, etc.) need their inner IDs saved for correct extract_image.
- **GPA memory leaks**: Multiple memory leaks in semantic.zig (injectBuiltins, overload map) and codegen.zig (emitExtensions). Not affecting correctness but causes GPA error output.

### Attempted approaches (all reverted):
- PP integration via `Preprocessor.process()` → 2 regressions (ocean.vert, ground.vert) due to OpStore codegen bug
- PP skip in `parseStatement` (no condition eval) → same regressions (both branches parsed, same root cause)

### Completed this session:
- Integer sampler types (20+ new AST types) + codegen + semantic support
- samplerCubeArrayShadow keyword + Dref instruction
- extract_image now uses sampler type to find correct inner image ID
- Total: 195→196 passes (+1)
