# Autoresearch Ideas

## HIGH PRIORITY — Fix swizzle via parser-level error recovery

### Root Cause
The lexer returns bare `.` as `double_literal`. This means `v.x` tokenizes as `identifier + double_literal + identifier`. Parser never creates `member_access` nodes. When fixed, ~20 compile errors would resolve, but ~10 previously-passing files regress because:
1. Parse errors are recoverable (synchronize skips statement)
2. Semantic errors kill entire functions (no recovery)
3. member_access on unexpected types (void, float, etc.) produces errors

### What's Been Tried (8+ attempts)
- Lexer fix: `has_dot` → `has_digit` only. Always regressed by 10+ passes.
- Parser fix: handle `double_literal` as dot. Same regression.
- Error recovery truncating instructions. Memory corruption (60 crashes).
- Error recovery nulling result_ids. Still crashes.
- **SUCCESS**: Error recovery with `break` on error (stop processing function, keep partial body). Works! +33 passes.
- Proper CompositeExtract for vectors. Works with error recovery.

### Current Status (commit 8966b3c)
**160 passes, 0 compile errors, 37 spirv-val failures.**
The swizzle fix is working! 37 spirv-val failures are from:
- Phantom IDs (forward referenced IDs not defined)
- Type mismatches in composite operations
- Wrong SPIR-V for texture functions
- Function overloading (duplicate IDs)
- Missing multisample image types

### Prerequisites for Safe Swizzle Fix
1. Semantic error recovery that doesn't leak memory (need Arena allocator or instruction ownership model)
2. Handle ALL member_access cases: void, float, struct, vector, array, sampler, named types
3. Handle multi-component swizzle (.xy, .xyz) with VectorShuffle
4. Handle swizzle writes as l-values

## MEDIUM PRIORITY

### Fix cfg.comp switch (1 spirv-val failure)
Proper OpSwitch with case labels and SelectionMerge.

### Fix partial-write-preserve.frag and type-alias.comp (2 spirv-val failures)
Function overloading support — both files have overloaded `overload(S0)` and `overload(S1)`.

### Fix texture-proj-shadow.desktop.frag (1 spirv-val failure)
Shadow sampler types need separate SPIR-V type with Depth=2.

### Fix texture-shadow-lod.frag (1 spirv-val failure)
OpExtInst word count issue for texture functions with shadow samplers.

### Add more missing GLSL builtins
- textureSamples/imageSamples (opcode 107, implemented but needs multisample image types)
- textureOffset, textureGather, etc.

## LOW PRIORITY

### Include inlining
`inlineIncludes` in `tests/runner.zig` works for Ghostty files.

### More image/sampler types with correct SPIR-V Dim/Multisampled/Depth parameters
Currently mapped to sampler2d/image2d which is wrong for many types.
