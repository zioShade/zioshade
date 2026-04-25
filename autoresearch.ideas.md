# Autoresearch Ideas Backlog

## Current State: 107 passes (from 104 at session start, +3 total)

## Session Progress (104→107, +3)
- Auto-load pointers in binary_op/func_call args/return (+1, 104→105, fixed array.flatten.vert spirv-val)
- Auto-load pointers in member_access handler (infrastructure, 105 unchanged)
- User-defined type var_decls via struct_names tracking + named type content comparison fix (+2, 105→107)
- Array suffix in parseLocalVarDecl (infrastructure, 107 unchanged)
- Comma-separated declarators: TRIED, caused crash (invalid free), REVERTED

## Key Blockers
1. **Swizzle Fix** (~19 assign_op|identifier errors): `.xy` tokenized as double_literal. 4+ failed attempts to fix.
2. **Switch Control Flow** (2 spirv-val): No-op switch produces invalid SPIR-V.
3. **Function Overloading** (1 spirv-val): Fundamental limitation.
4. **Comma-separated declarators**: Caused crash, needs careful implementation.

## Remaining Spirv-Val Failures (4)
1. **cfg.comp**: Switch no-op — "block must end with branch"
2. **cfg-preserve-parameter.comp**: Switch + OpStore type issue
3. **partial-write-preserve.frag**: Function overloading — "Id defined more than once"
4. **type-alias.comp**: Function overloading — "Id defined more than once"

## Quick Win Candidates
- Matrix-vector multiply (v0 * f.MVP0 where MVP0 is mat3x4) — needs OpMatrixTimesVector etc.
- Missing sampler types (sampler1D, samplerCube, samplerCubeArray)
- normalize() builtin — 2 files need it (ocean.vert, ground.vert)
- modf() builtin — 2 files need it
- group() builtins (subgroup operations) — 2 files
- For-loop comma-separated init — needs crash-free implementation
- `return-array.vert` — function returning array type

## Error Distribution (86 compile errors)
- 19 assign_op|identifier (swizzle-related)
- 7 assign_op|func_call (unsupported builtins)
- 6 type_constructor|identifier (user-type constructor issues)
- 5 index_access|identifier (swizzle-related)
- 5 binary_op|identifier (various)
- 4 compound_assign|func_call (unsupported sampler types)
- 4 beginInvocationInterlockARB (fragment shader interlock)
- 4 assign_op|assign_op (mixed: 16-bit types, stencil export, composite construct)
- 3 normalize|identifier (missing builtin)
- 2 var_decl (empty inner — mat3x4 issues)
