# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance, optimizing SPIR-V output size

### Completed this session:
- ✅ Lazy builtin injection: only declare gl_* variables when referenced (semantic.zig)
- ✅ Minimal capability emission: conditional ImageQuery, SubgroupVoteKHR, etc. (codegen.zig)
- ✅ Conditional extension emission: SPV_KHR_subgroup_vote only when needed
- ✅ Conditional constant pre-emit: only emit atomic/float/uint constants when used
- ✅ Pre-emit only vec2/vec3/vec4 (not ivec/uvec/mat) — avoids section ordering violations

### Metrics progress:
| Iteration | our_bound | ref_bound | overhead | our_vars | ref_vars |
|-----------|-----------|-----------|----------|----------|----------|
| Baseline  | 29142     | 10159     | 2.87x    | 6782     | 1010     |
| After #1  | 21979     | 10159     | 2.16x    | 879      | 1010     |
| After #2  | 20563     | 10159     | 2.02x    | 879      | 1010     |

### Next opportunities (by impact):
1. **Entry point variable list**: We may list unused variables in OpEntryPoint. glslang only lists vars actually used in the function.
2. **Constant deduplication**: Multiple constants with the same value may be emitted. `emitIntConstant` should check if constant already exists.
3. **Function parameter passing**: We pass by value, glslang passes by pointer for out/inout params. Semantic difference for write-back.
4. **OpVariable for params**: We create local vars for ALL params, glslang only for those written to.
5. **Dead code elimination**: Unused local variables still get OpVariable declarations.
