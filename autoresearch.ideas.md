# Autoresearch Ideas Backlog

## Current State: 104 passes (from 92 at session start, +12 total)

## Session Progress (92→104, +12)
- Push constant + array dedup + member ptr pre-emit (infrastructure, 92→98)
- Index_access l-value for compound assignments (+1, 98→99)
- Member-level layout() qualifiers in struct/uniform blocks (+1, 99→100)
- Struct constructors (OpCompositeConstruct) + type_sym phantom ID fix + pointer cache key fix (+1, 100→101)
- Array size suffix in parseVarDecl for global arrays (+2, 101→103)
- CompositeExtract for constant-index array access on loaded values (+1, 103→104)
- flat/smooth/noperspective keyword parsing (infrastructure, no gain)
- #extension preprocessor skip (infrastructure)

## Key Blockers
1. **Swizzle Fix** (~42 compile errors): `.xy` tokenized as double_literal. 4 failed attempts to fix.
2. **User-Defined Type Var Decls** (~5+ compile errors): `Foo f = ...;` can't parse because `Foo` isn't a type keyword. Adding `identifier identifier` detection breaks 5 other files due to pointer/value mismatch in the semantic.
3. **Pointer/Value Mismatch**: Access chains return pointers, expressions expect values. Need auto-load after access chains.
4. **Switch Control Flow** (2 spirv-val): No-op switch produces invalid SPIR-V.
5. **Function Overloading** (1 spirv-val): Fundamental limitation.

## Quick Win Candidates
- `copy.flatten.vert` (+1 spirv-val): `Light light = lights[i]` — needs user-type var_decl + pointer/value fix
- `constant-composites.frag`: Array constructors + user-type var_decls
- `struct.rowmajor.flatten.vert`: User-type var_decl `Foo f = foo;`
- Missing sampler types for image-query files (sampler1D, samplerCube, samplerCubeArray)
- `textureLodOffset` builtin variant

## Remaining Spirv-Val Failures (4)
1. **array.flatten.vert**: Chained access chains produce pointers not values
2. **cfg.comp**: Switch no-op — "block must end with branch"
3. **cfg-preserve-parameter.comp**: Switch no-op + OpStore type issue
4. **type-alias.comp**: Function overloading — fundamental limitation
