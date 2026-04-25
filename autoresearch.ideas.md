# Autoresearch Ideas Backlog

## Current State: 101 passes (from 92 at session start, +9 total)

## Session Progress (92→101)
- Push constant + array dedup + member ptr pre-emit (infrastructure, 92→98)
- Index_access l-value for compound assignments (+1, 98→99)
- Member-level layout() qualifiers in struct/uniform blocks (+1, 99→100)
- Struct constructors (OpCompositeConstruct) + type_sym phantom ID fix (+1, 100→101)
- Also: #extension preprocessor skip, ensurePointerType cache key fix

## Swizzle Fix — BLOCKED (4 failed attempts)
The #1 opportunity. ~42/92 compile errors are swizzle-related.
- Root cause: lexer tokenizes `.xy` as double_literal, not `dot` + `identifier`
- Fixing lexer/parser creates member_access nodes semantic can't handle
- Need to make semantic handle ALL member_access cases before changing lexer/parser
- isSwizzleName helper + vector swizzle code exists but dormant

## User-Defined Type Var Decls — BLOCKED
Pattern `StructType varName = ...;` inside function bodies is NOT parsed as var_decl.
- Parser's `isTypeKeyword` only knows built-in types
- `identifier identifier` detection causes regressions (breaks 5+ files)
- Needs a smarter approach: maintain a set of known struct names in the parser
- This blocks ~5 files that use struct local variables with function calls

## Pointer/Value Mismatch — Infrastructure Issue
Access chains return pointers, but expressions expect values.
- block_member array types return pointers (for chaining)
- index_access creates access chains but doesn't load the result
- var_decl stores need values, not pointers
- Need: auto-load after access chain when value context is expected
- Affects: array.flatten.vert, copy.flatten.vert, struct member access in some contexts

## Remaining Spirv-Val Failures (4)
1. **array.flatten.vert**: Chained access chains produce pointers, need loads
2. **cfg.comp**: Switch no-op — "block must end with branch"
3. **cfg-preserve-parameter.comp**: Switch no-op + OpStore type issue
4. **type-alias.comp**: Function overloading — fundamental limitation

## Quick Win Opportunities
- `flush_params.frag`: Needs `identifier identifier` var_decl parsing for user types
- `constant-composites.frag`: `const` array initializers
- `demote-to-helper.vk.nocompat.frag`: Missing `demote` builtin (OpDemoteToHelperInvocationEXT)
- `image-query.desktop.frag`: Missing sampler types (sampler1D, samplerCube, etc.)
- `shader_trinary_minmax.comp`: Missing `min3`/`max3` builtins

## Infrastructure Added
- ptr_storage_class tracking in codegen (for chained access chains)
- Struct constructor detection (type_sym → OpCompositeConstruct)
- ensurePointerType uses type ID as cache key (not enum value)
- Multi-dimensional array type parsing (while loop instead of if)
- #extension preprocessor skip
