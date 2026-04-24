# Autoresearch Ideas

## High Priority
- **Fix `[]` parsing in uniform blocks (3rd attempt)**: The `[]` after member names causes parser to consume tokens that break other parsing. Root cause: the `l_bracket` token is also used for attribute syntax and fixed-size arrays. Need to only consume `[]` when in a uniform/buffer block context, not globally. The is_runtime_array flag approach works in the semantic analyzer but the parser change regresses.
- **Fix phantom IDs for `member_access` on vectors**: `vec4.x` returns phantom ID (no instruction). Needs OpLoad + OpCompositeExtract. But the lexer `.` bug complicates this.
- **Fix `outerProduct` result type**: Should be mat{N}x{M}, not vec{N}. Same for other builtins with different result types.
- **Add `imageLoad`/`imageStore`/`imageSize` SPIR-V ops**: These need OpImageRead/OpImageWrite/OpImageQuerySize, not ext_inst.

## Medium Priority
- **Fix result types for bitcast builtins**: `floatBitsToInt` → int (not float), `intBitsToFloat` → float, etc. Currently uses first arg type.
- **Add proper OpControlBarrier/OpMemoryBarrier for barrier builtins**: Currently void stubs.
- **Fix "Duplicate non-aggregate type declarations"**: `outer-product.comp` and `barriers.comp` emit duplicate OpTypeMatrix/OpTypeFunction. Might be from ensureType recursion or named type overlap.
- **Fix "Operand requires previous definition"**: 6 files with undefined IDs. Check all remaining phantom ID patterns.
- **Implicit load for variable references**: When global/local vars used in expressions, may need OpLoad before use.

## Low Priority
- **`flat`, `centroid`, `sample`, `noperspective` qualifiers**: In-block qualifiers need parsing.
- **Switch statements**: 4 valid test files use switch. Needs OpSwitch.
- **`#include` preprocessor**: Ghostty shaders need it, classified as INVALID.
- **User-defined function return values**: `flush_params.frag` — function returns struct but semantic analyzer returns void for user-defined function calls.
