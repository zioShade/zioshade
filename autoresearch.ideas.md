# Autoresearch Ideas

## HIGH PRIORITY — Swizzle Fix (est. +15-20 passes if done right)

### Root Cause
The tokenizer returns bare `.` as `double_literal` (len=1, text=".") because `tryParseNumber` returns non-null for `has_dot=true, has_digit=false`. This means `v.x` is tokenized as `v` (identifier) + `.` (double_literal) + `x` (identifier). The `.dot` handler in the parser is never reached.

### Parser Fix (verified working)
In parsePostfix, add `.double_literal` to the `.dot` case. When the double_literal text is exactly ".", treat it as the dot operator:
```zig
.dot, .double_literal => {
    if (self.current().tag == .double_literal) {
        const tok_text = self.text(self.current());
        if (tok_text.len != 1 or tok_text[0] != '.') break;
    }
    _ = self.advance(); // consume '.'
    const member_tok = self.current();
    _ = self.advance(); // consume member name
    ...
```

### Semantic Fix (verified working)
- Single-component swizzle (`.x`): OpCompositeExtract — WORKS, produces valid SPIR-V
- Multi-component swizzle (`.xy`): OpVectorShuffle — WORKS, produces valid SPIR-V
- Added `toVec2()`/`toVec3()` to ast.Type for VectorShuffle result types

### Why it Regresses 12-17 passes
Files that previously had swizzle statements SILENTLY DROPPED by parser error recovery now fail because:
1. Swizzle on non-vector types (matrices, function return values) — semantic returns base_tid which may cause type mismatch
2. Files using `gl_BaryCoordEXT` (vec3) which isn't declared as a variable
3. Two files crash with "Invalid free" during deinit — memory corruption from codegen

### To Make It Work
1. Fix the 2 crashes: `dowhile.comp` and `torture-loop.comp` — need to debug memory corruption
2. Handle member_access on non-vector types gracefully (return appropriate type)
3. Accept that some previously-passing files will now fail differently (net improvement should still be positive)

### Experiment Results
- Phantom IDs (no VectorShuffle): 120→103 (-17)
- With VectorShuffle: 120→108 (-12)
- With VectorShuffle + crash protection: 120→108 (-12) still crashes

## MEDIUM PRIORITY

### Switch codegen (2 spirv-val failures)
`cfg.comp` and `cfg-preserve-parameter.comp`. Need proper OpSwitch with case labels. Break inside switch needs a switch_stack (like loop_stack). Previous attempts all regressed 3+ files.

### Function overloading (2 spirv-val failures)
`partial-write-preserve.frag` and `type-alias.comp`. Need type-aware function dispatch — match function by parameter types.

### Shadow samplers (1 spirv-val failure)
`texture-proj-shadow.desktop.frag` needs `sampler2DShadow` type.

### Texture offset builtins
Adding `textureLodOffset`, `texelFetchOffset` etc. caused 1 regression. Need to investigate why — might be that files using these functions now produce different (wrong) SPIR-V.

## LOW PRIORITY

### Scalar-from-vector type conversion
`int(vec4)` and `float(vec4)` now extract first component via OpCompositeExtract. Committed at fc16688. No pass count improvement but correct behavior.

### OpVectorShuffle infrastructure
Working implementation exists — used for multi-component swizzle and matrix column shrinking. Proven to produce valid SPIR-V.

### Include inlining
`inlineIncludes` in `tests/runner.zig` works for Ghostty files. Blocked by swizzle (common.glsl has swizzle operations).

### More sampler types
`sampler1D`, `sampler3D`, `samplerCube`, `sampler2DShadow`
