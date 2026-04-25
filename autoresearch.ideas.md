# Autoresearch Ideas Backlog

## High Priority

- **Fix swizzle on func_call result**: `texture(sampler, coord).x` fails when output variable exists. The member_access handler evaluates the swizzle, but something goes wrong with the var_decl. 48 assign_op errors may be related.

- **Fix int->float conversion in type constructors**: `vec4(v)` where v is int should convert to float first. Currently creates OpCompositeConstruct with int arg for float vector.

- **Fix remaining phantom IDs** (6 files): spv.nvAtomicFp16Vec, combined-texture-sampler-shadow, image-ms, texture_buffer, int64, struct-packing. Root cause: ensureType(.named) returns allocated ID without emitting instruction when type not registered. Need more type keywords or better fallback.

- **Fix "Branch must appear in a block"** (2 files): selection-block-dominator, switch-nested. One has type conversion issue (vec4(int)), other likely switch statement support needed.

- **Fix OpReturn non-void** (3 link files): link.multiBlocks*.vert. Functions with non-void return need OpReturnValue, not OpReturn.

- **Fix execution model for texture sampling** (2 files): explicit-lod.legacy.vert, implicit-lod.legacy.vert. Callgraph contains function calling texture sampling in non-fragment stage.

## Medium Priority

- **Proper iimage2D/uimage2D type support**: Currently mapped to image2d (float sampled type). iimage2D should use int sampled type. Causes OpStore type mismatches.

- **Fix mat3(mat4) conversion**: matrix-conversion.flatten.frag. Need to extract 3 columns from mat4 and construct mat3.

- **Fix OpTypePointer in wrong section**: struct-flatten-stores.legacy.vert. Type declarations after function definitions.

- **Switch statement support**: Need OpSwitch implementation.

- **Function overloading**: type-alias.comp has two `overload()` functions with different param types. Fundamental limitation of single-symbol lookup.

## Tried & Failed / Stale

- **Fix lexer '.' tokenization**: `.` alone classified as double_literal. Fixing causes 57→35 regression. The `accum.y` pattern works despite this bug somehow.
- **Array bracket parsing in uniform blocks**: 4 attempts failed, all regressed.
