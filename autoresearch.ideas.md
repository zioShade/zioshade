# Autoresearch Ideas Backlog

## Critical Path (Biggest Impact)

- **Fix lexer '.' + parser swizzle + semantic swizzle (TRIPLE FIX)**: The '.' is tokenized as double_literal even for `v.xy`. The fix requires THREE changes together:
  1. **Lexer**: `tryParseNumber` should return null for `.` not followed by digit
  2. **Parser**: parsePostfix .dot case needs evaluation-order fix (DONE in commit 01d4a19)
  3. **Semantic**: member_access handler needs proper swizzle codegen (CompositeExtract for single, VectorShuffle for multi)
  
  The triple fix was attempted but caused 83→61 regression. Root cause: some files that previously had swizzles silently ignored (phantom IDs producing wrong types) now produce correct types that conflict with other parts of the shader. Need to identify and fix those cascading issues.

- **Remaining spirv-val failures** (12 files): Phantom IDs (3), execution model (2), iimage2D type (2), texture_buffer (1), matrix conversion (1), struct-flatten (1), type-alias (1), depth unchanged (1).

## Medium Priority

- **Fix struct type constructor functions**: struct-flatten-stores references functions Foo(), Bar(), Baz() that are never emitted. Need to emit type constructors as SPIR-V functions.

- **Proper iimage2D/uimage2D type support**: Currently all image types mapped to image2d (float sampled type). Requires adding types to ast.zig.

- **Fix mat3(mat4) conversion**: matrix-conversion.flatten.frag.

- **Fix texture_buffer.vert**: Need OpImage extraction from sampled image before OpImageFetch.

- **Switch statement support**: 3 files use switch.

- **Function overloading**: type-alias.comp — fundamental limitation.

## Done / Tried & Failed

- **Lexer '.' fix alone**: Causes 83→56 regression (27 files). Must be paired with proper swizzle codegen.
- **Lexer + swizzle (without parser fix)**: 83→56 regression.
- **Lexer + parser + swizzle**: 83→61 regression. Parser fix is correct but cascading type issues remain.
- **Array bracket parsing in uniform blocks**: 4 attempts failed, all regressed.
- **preEmitPointerTypes**: Exposed deeper bug with struct type constructors.
- **Fix int→float conversion in type constructors**: DONE.
- **Fix "Branch must appear in a block"**: DONE.
- **Fix OpReturn non-void**: DONE.
