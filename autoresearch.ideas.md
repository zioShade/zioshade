# Autoresearch Ideas Backlog

## Current State: 119 passes (from 110 at session start, +9 total)

## Session Progress (110→119, +9)
- Added GL builtins (gl_LocalInvocationIndex, gl_SampleMaskIn, etc.) + fixed BuiltIn enum values (+2, 110→112)
- Added barrier/interlock builtins (beginInvocationInterlockARB, endInvocationInterlockARB) + atomic builtins (+3, 112→115)
- Add min3/max3/mid3 builtins with proper int/float type dispatch (+1, 115→116)
- Add gl_DrawID + gl_DrawIDARB builtins (+2, 116→118)
- Add gl_FragStencilRefARB builtin (+1, 118→119)
- Added #include preprocessor directive support (skip, no pass change)
- Comma-separated declarators: TRIED, causes crash (for-loop-init.frag has i.x += 4 swizzle that triggers access_chain with non-id operand)

## Key Blockers
1. **Swizzle Fix** (~17 errors): Requires lexer change. Tried 6+ times across sessions, always regresses 20-30 files.
2. **Switch Control Flow** (2 spirv-val): No-op switch produces invalid SPIR-V. Need proper OpSwitch.
3. **Function Overloading** (2 spirv-val): Fundamental limitation — same function name with different params.
4. **#include for Ghostty** (6 compile errors): Need to read common.glsl and inject declarations.
5. **Shadow samplers** (1 spirv-val): texture-proj-shadow.desktop.frag needs sampler2DShadow + textureProj with Dref.
6. **Comma declarators**: Parser change works but crashes on files that have swizzle in for-loop update.

## Remaining Spirv-Val Failures (5)
1. **cfg.comp**: "Block must end with branch" — switch no-op
2. **cfg-preserve-parameter.comp**: "OpStore type for pointer is not a pointer type"
3. **partial-write-preserve.frag**: "Id defined more than once" — function overloading
4. **texture-proj-shadow.desktop.frag**: "Expected Sampled Image to be of type OpTypeSampledImage"
5. **type-alias.comp**: "Id defined more than once" — function overloading

## Error Distribution (73 compile errors)
- 15 func_call (unsupported builtins)
- 9 empty (Ghostty files needing #include)
- 9 xy (swizzle)
- 8 x (swizzle)
- 5 bools (Ghostty)
- 5 assign_op (various)
- 4 index_access (various)
- 4 compound_assign (unsupported builtins)
- + many 1-2 count errors

## Promising Next Steps
1. **#include for Ghostty** (+6 potential): Read common.glsl and inject. Significant engineering effort.
2. **Sampler types expansion**: sampler1D, sampler3D, samplerCube, shadow variants. Many files use these.
3. **textureGather/textureOffset**: Add as builtins with proper SPIR-V ops.
4. **Proper switch codegen**: Need OpSwitch with case labels.
5. **Comma declarators**: Parser change works but blocked by swizzle crash. Fix swizzle first.
