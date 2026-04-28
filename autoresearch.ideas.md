# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance, SPIR-V output at glslang parity

### Metrics progress:
| Iteration | our_bound | ref_bound | overhead | our_vars | ref_vars |
|-----------|-----------|-----------|----------|----------|----------|
| Baseline  | 29142     | 10159     | 2.87x    | 6782     | 1010     |
| Lazy builtins | 21979 | 10159     | 2.16x    | 879      | 1010     |
| Type pre-emit | 20563 | 10159     | 2.02x    | 879      | 1010     |
| Conditional   | 19810 | 10159     | 1.95x    | 879      | 1010     |
| Precise caps  | 19145 | 10159     | 1.88x    | 879      | 1010     |
| ID waste fix  | 10015 | 10159     | 0.99x ✅ | 879      | 1010     |

### Key breakthrough: Function builtin IR IDs
50+ function builtins (abs, sin, cos, texture, dFdx, etc.) each called `allocId()` 
during semantic analysis, wasting SPIR-V IDs. Codegen never uses these IDs.
Fix: set `ir_id = 0` for all function builtins. front-facing.frag: 22 vs 22 (exact parity).

### Remaining opportunities (minor):
1. **Our bound is BELOW glslang's**: We may be missing some necessary IDs, or our
   variable count (879 vs 1010) suggests we're not creating enough variables.
   Need to investigate if this is correct or a bug.
2. **Variable count delta**: We have fewer variables than glslang (879 vs 1010).
   This might mean some params aren't getting proper storage.
3. **Per-shader analysis**: Some shaders may still have overhead. Run differential
   comparison to find outliers.
