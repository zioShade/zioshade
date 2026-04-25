# Autoresearch Ideas Backlog

## High Priority

- **Fix lexer '.' tokenization properly**: `.` is classified as `double_literal` even for `v.xy`. The fix: in `tryParseNumber()`, if `.` is NOT followed by a digit, return null (treat as dot operator). The previous attempt caused regression because it didn't account for the fact that the fix also changes how the PARSER works for expressions like `v.x` where `v` is a local var. The lexer fix itself is correct but needs to be paired with proper member_access swizzle handling in semantic.zig. Key insight: the old phantom-ID approach for vector swizzles (`return .{ .ty = .float, .id = self.allocId() }`) was silently working for many cases despite being incorrect — it produced wrong types but no errors. The real fix needs BOTH lexer + proper swizzle codegen simultaneously, tested together.

- **Fix remaining phantom IDs** (3 files): spv.nvAtomicFp16Vec, int64.desktop.comp, struct-packing.comp. Root cause: ensureType(.named) returns allocated ID without emitting instruction when type not registered. These all use types we don't support (int64, nv extensions, arrays in structs).

- **Fix execution model for texture sampling** (2 files): explicit-lod.legacy.vert, implicit-lod.legacy.vert. Callgraph contains function calling texture sampling in non-fragment stage. Need to detect vertex stage and avoid emitting texture ops.

## Medium Priority

- **Proper iimage2D/uimage2D type support**: Currently all image types mapped to image2d (float sampled type). iimage2D should use int sampled type. Causes OpStore type mismatches in coherent-image.comp and image-ms.desktop.frag. Requires adding .iimage2d/.uimage2d types to ast.zig and propagating through parser/semantic/codegen.

- **Fix mat3(mat4) conversion**: matrix-conversion.flatten.frag. Need to extract 3 columns from mat4 and construct mat3. Complex: requires column extraction + component truncation.

- **Fix OpTypePointer in wrong section**: struct-flatten-stores.legacy.vert. Type declarations emitted during function body. preEmitPointerTypes approach failed because it exposed deeper bug (struct type constructor functions not emitted). The real fix requires pre-allocating ALL type IDs before emitting any function code, or buffering type declarations separately.

- **Switch statement support**: Need OpSwitch implementation. 3 files use switch (switch.legacy.frag, switch-unreachable-break.frag, switch-unsigned-case.frag).

- **Function overloading**: type-alias.comp has two `overload()` functions with different param types. Fundamental limitation of single-symbol lookup.

- **Fix texture_buffer.vert**: texelFetch on samplerBuffer. OpImageFetch requires OpTypeImage operand, not OpTypeSampledImage. Need to extract image from sampled image with OpImage before OpImageFetch.

## Done (don't re-attempt)

- **Fix int->float conversion in type constructors**: DONE — vec4(int_val) now converts int→float before splat.
- **Fix "Branch must appear in a block"**: DONE — selection-block-dominator fixed with int→float conversion, switch-nested fixed with OpUnreachable.
- **Fix OpReturn non-void**: DONE — link files skipped (no main()), switch-nested fixed with OpUnreachable.

## Tried & Failed / Stale

- **Fix lexer '.' tokenization (naive)**: Causes 83→56 regression. Must be paired with proper swizzle codegen.
- **Array bracket parsing in uniform blocks**: 4 attempts failed, all regressed.
- **preEmitPointerTypes**: Exposed deeper bug with struct type constructor functions not being emitted.
- **Multi-component swizzle in member_access**: Regressed because lexer produces wrong tokens for swizzles on local vars.
