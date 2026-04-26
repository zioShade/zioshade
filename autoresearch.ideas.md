# Autoresearch Ideas

## High Priority

### Swizzle / member access (THE BIG BLOCKER - ~30 files affected)
**Key insight discovered**: `.` is tokenized as `double_literal` (len=1, text=".") by `tryParseNumber` because `has_dot=true, has_digit=false` returns non-null. This means `v.x` is parsed as `v` (identifier) + `.` (double_literal) + `x` (identifier). The `.dot` token handler in the parser is NEVER reached because `tryParseNumber` claims the `.` first.

**The fix**: Make `tryParseNumber` return null for bare `.` (no digits). This makes `.` fall through to the operator handler → `.dot` token.

**Why it regressed 30+ files**: Files that had `v.x` expressions previously had those statements SILENTLY DROPPED by the parser (parseBlock catches errors and skips). With the fix, the statements are properly parsed as member_access nodes. But:
- Multi-component swizzle (`.xy`, `.xyz`) produces phantom IDs → spirv-val failures
- Swizzle on complex types (mat2x2, function return values) may fail
- The phantom IDs from multi-component swizzle cascade to other instructions

**Required for swizzle fix to succeed**:
1. Lexer: bare `.` → `.dot` (simple change)
2. Semantic: single-component swizzle → OpCompositeExtract (done, works)
3. Semantic: multi-component swizzle → OpVectorShuffle (NOT done - currently phantom)
4. Semantic: handle member_access on non-vector types (matrices, structs with vector members)
5. Accept that some files that "passed" before (because swizzle statements were dropped) will now fail differently

**Potential approach**: Instead of trying to fix ALL swizzle cases, what if the lexer fix only applies in certain contexts? E.g., only make `.` → `.dot` when the previous token is an identifier or `)`? This is a context-sensitive lexer change.

**Alternative approach**: Fix it in the parser instead of the lexer. When parsePostfix encounters a `double_literal` token with text ".", treat it as `.dot` and look for an identifier next. This was attempted but had issues because the double_literal token for `.` has len=1 and text="." (doesn't include the identifier).

### Actually... the parser approach CAN work
The `double_literal` token with text "." can be treated as `.dot` in parsePostfix:
1. See `double_literal` token with text "."
2. Consume it (advance)
3. The next token is the member name (identifier)
4. Advance past the identifier
5. Create member_access node

This is simpler than the lexer fix and doesn't affect any other part of the tokenizer.

### Comma-separated declarators in parseLocalVarDecl
Parser change works but exposes a bug in access_chain codegen when swizzle patterns appear in for-loop updates. The `i.x += 4` pattern triggers invalid `access_chain` operand. Reverted.

## Medium Priority

### Switch codegen (2 spirv-val failures)
`cfg.comp` and `cfg-preserve-parameter.comp` — switch is a no-op, produces "block must end with branch". Need proper OpSwitch emission with case labels and branches. Break inside switch needs to branch to the switch merge label (requires a `switch_stack` similar to `loop_stack`).

### Function overloading (2 spirv-val failures)
`partial-write-preserve.frag` and `type-alias.comp` — same function name with different parameter types. Requires type-aware function dispatch.

### Shadow samplers
`texture-proj-shadow.desktop.frag` needs `sampler2DShadow` type support.

## Low Priority

### OpVectorShuffle for multi-component swizzle
Needed for `.xy`, `.xyz`, `.xxyy` etc. Currently these produce phantom IDs which cause cascading failures.

### More sampler types
`sampler1D`, `sampler3D`, `samplerCube`, `sampler2DShadow`, `sampler1DShadow` — many files use these.

### textureGather builtin
Needs `OpImageGather` and shadow sampler support.

### Include inlining
`inlineIncludes` in `tests/runner.zig` works for Ghostty files. But the included `common.glsl` has swizzle and other features that are blocked. The infrastructure is ready.
