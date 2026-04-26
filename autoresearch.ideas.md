# Autoresearch Ideas

## HIGH PRIORITY — Parser Dot Tokenization Bug

### Root Cause
The tokenizer returns bare `.` as `double_literal` (len=1, text=".") because `tryParseNumber` returns non-null for `has_dot=true, has_digit=false`. This means `v.x` is tokenized as `v` (identifier) + `.` (double_literal) + `x` (identifier). The `.dot` handler in the parser is never reached.

### Why Parser-Only Fix Causes Regressions
Fixing the parser to handle `double_literal` with text "." as the dot operator makes `ssbo1.a` parse correctly (member_access). Previously, `ssbo1.a` failed to parse (because `.` was `double_literal`, not `dot`) and the entire statement was dropped by error recovery. Files like `enhanced-layouts.comp` passed with empty main() functions.

With the parser fix, these statements now parse correctly, but the semantic analyzer fails because:
1. `analyzeExpression` loads the entire struct variable as a value (OpLoad on the whole buffer block)
2. Then tries composite_extract to get member — but SPIR-V can't load an entire buffer block
3. The lvalue path for `ssbo1.a = val` also fails because the base is a loaded value, not a pointer

### Prerequisites for Swizzle Fix
Before applying the parser fix, we need to fix struct member access in the semantic analyzer:
1. For `base.named` expressions where the base came from loading a pointer to a named type, use OpAccessChain instead of OpCompositeExtract
2. For lvalue member access, keep the base as a pointer (don't load it)
3. Only then apply the parser + semantic swizzle fix

### Estimated Impact
+11-20 net passes (11 new from swizzle, minus 0 regressions after prerequisites are fixed)

## MEDIUM PRIORITY

### Fix lexer: bare '.' should be dot, not double_literal
Fix in lexer.zig `tryParseNumber`: return null when text is just "." (no digits). This is the cleaner fix but has same prerequisite as above.

### Switch codegen (2 spirv-val failures)
`cfg.comp` and `cfg-preserve-parameter.comp`. Need proper OpSwitch.

### Function overloading (2 spirv-val failures)
`partial-write-preserve.frag` and `type-alias.comp`.

### Shadow samplers (1 spirv-val failure)
`texture-proj-shadow.desktop.frag` needs `sampler2DShadow`.

## LOW PRIORITY

### Include inlining
`inlineIncludes` in `tests/runner.zig` works for Ghostty files.

### More sampler types
`sampler1D`, `sampler3D`, `samplerCube`, `sampler2DShadow`
