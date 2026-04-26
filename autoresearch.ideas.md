# Autoresearch Ideas Backlog

## Current State: 107 passes (from 104 at session start, +3 total)

## Session Progress (104→107, +3)
- Auto-load pointers in binary_op/func_call args/return (+1, 104→105, fixed array.flatten.vert spirv-val)
- Auto-load pointers in member_access handler (infrastructure, 105 unchanged)
- User-defined type var_decls via struct_names tracking + named type content comparison (+2, 105→107)
- Array suffix in parseLocalVarDecl (infrastructure, 107 unchanged)
- Member_access l-value fix: proper access chains for struct writes (infrastructure, 107 unchanged)
- Swizzle/lexer fix: TRIED, regressed 107→76. Member_access now works for structs but out/inout param ptr tracking needed before lexer change.
- textureQueryLevels/textureProj: IN PROGRESS, handler fires but codegen produces wrong opcode. Need to debug.

## Key Blockers
1. **Swizzle Fix** (~20 assign_op|identifier errors): Requires lexer change + semantic handling. Blocked by out/inout param pointer tracking.
2. **Switch Control Flow** (2 spirv-val): No-op switch produces invalid SPIR-V.
3. **Function Overloading** (2 spirv-val): Fundamental limitation.

## Remaining Spirv-Val Failures (4)
1. **cfg.comp**: Switch no-op — "block must end with branch"
2. **cfg-preserve-parameter.comp**: Switch + OpStore type issue
3. **partial-write-preserve.frag**: Function overloading — "Id defined more than once"
4. **type-alias.comp**: Function overloading — "Id defined more than once"

## Error Distribution (86 compile errors)
- 20 assign_op|identifier (swizzle-related)
- 7 assign_op|func_call (unsupported texture builtins: textureProj, textureQueryLevels, etc.)
- 6 type_constructor|identifier (swizzle + user-type constructor issues)
- 5 index_access|identifier (swizzle-related)
- 5 binary_op|identifier (swizzle + other)
- 4 compound_assign|func_call (unsupported texture builtins)
- 4 beginInvocationInterlockARB (fragment shader interlock)
- 3 normalize|identifier (all blocked by swizzle)
- 3 assign_op|assign_op (mixed: 16-bit types, stencil export)

## Quick Win Candidates
- **textureProj**: Simple file (sampler-proj.frag). Uses OpImageSampleProjImplicitLod (opcode 92). Need to debug codegen issue.
- **textureQueryLevels**: query-levels.desktop.frag. Uses OpImageQueryLevels (opcode 91). Handler fires but wrong opcode in output.
- **sampler-ms-query.desktop.frag**: Uses texture(sampler2DMS, ...) which needs different handling
- **texture-proj-shadow.desktop.frag**: textureProj with shadow sampler

## Architecture Notes
- The swizzle fix chain: 1) member_access l-value (DONE), 2) out/inout param pointer types in codegen (HARD), 3) then lexer change
- textureQueryLevels handler at semantic line ~1393 fires correctly but codegen produces wrong opcode. Possible IR tag resolution issue.
