# Autoresearch Ideas Backlog

## High Priority (likely to fix multiple spirv-val failures)

- **Fix "block must end with branch" (4 files)**: false-loop-init.frag, hoisted-temporary.frag, inside-loop-dominated.frag, shader-debug-info.frag. Root cause: if/for control flow analysis doesn't emit proper OpBranch for all code paths. Need to ensure every basic block ends with a branch instruction. May need to add a "fallthrough" OpBranch at the end of if/else blocks.

- **Fix phantom IDs (6 files)**: spv.nvAtomicFp16Vec.frag, combined-texture-sampler-shadow.vk.frag, image-formats.comp, int64.desktop.comp, struct-packing.comp, coherent-image.comp. Root cause: IDs allocated but never emitted as results. Could be from ensureType allocations that don't get emitted, or from code paths that allocate IDs but error out.

- **Fix ext_inst word count for length/distance/normalize on scalars (3 files)**: scalar-std450-distance-length-normalize.comp, texture_buffer.vert, coherent-image.comp. GLSL.std.450 Length/Distance/Normalize take 1 arg (not 2). When called with scalar args, our generic ext_inst passes all args.

## Medium Priority

- **Proper image2D/iimage2D/uimage2D type support**: Currently mapped to sampler2d. Need separate types for SPIR-V. imageLoad on iimage2D returns ivec4, not vec4.

- **Fix mat3(mat4) conversion**: matrix-conversion.flatten.frag. Need to extract 3 columns from mat4 and construct mat3.

- **Fix execution model for texture sampling**: explicit-lod.legacy.vert, implicit-lod.legacy.vert. Need to use OpImageSampleExplicitLod for non-fragment stages.

- **Fix modf result type**: modf.legacy.frag. ModfStruct (GLSL.std.450 #36) returns a struct type, not the input type. Need to create the struct type and extract components.

- **Function overloading support**: type-alias.comp has two `overload()` functions with different param types. Our semantic analyzer can't handle this — it maps names to single symbols.

- **Fix "Branch must appear in a block"**: selection-block-dominator.frag, switch-nested.legacy.vert. Likely same root cause as "block must end with branch" — control flow structure issues.

- **Fix OpReturn non-void**: link.multiBlocksInvalid.0.1.vert etc. Functions with non-void return type need OpReturnValue, not OpReturn.

- **Fix OpTypePointer in wrong section**: struct-flatten-stores.legacy.vert. Type declarations after function definitions are invalid.

## Low Priority / Deferred

- **Array bracket parsing in uniform blocks**: `buffer SSBO { vec4 data[]; }` — 4 attempts failed, all regressed. Root cause: parser change affects non-array blocks.

- **Lexer '.' tokenization bug**: `.` alone classified as double_literal. Fixing causes 22-shader regression. Related to `accum.y` tokenization.

- **Switch statement support**: Need OpSwitch implementation for switch statements.
