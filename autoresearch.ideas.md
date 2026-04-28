# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance, SPIR-V output optimization

### Metrics progress:
| Iteration | our_bound | ref_bound | overhead | our_vars | ref_vars |
|-----------|-----------|-----------|----------|----------|----------|
| Baseline  | 29142     | 10159     | 2.87x    | 6782     | 1010     |
| Lazy builtins | 21979 | 10159     | 2.16x    | 879      | 1010     |
| Type pre-emit | 20563 | 10159     | 2.02x    | 879      | 1010     |
| Conditional   | 19810 | 10159     | 1.95x    | 879      | 1010     |

### Key changes made:
1. **Lazy builtin injection** (semantic.zig): gl_* vars only created when referenced
2. **Minimal capabilities** (codegen.zig): conditional ImageQuery/SubgroupVoteKHR
3. **Conditional extensions** (codegen.zig): SPV_KHR_subgroup_vote only when needed
4. **Conditional type/constant pre-emit**: only emit types/constants that are actually used
5. **Fixed spirv.zig**: group_vote was wrong value (44=Image1D), use subgroup_vote_khr=4431

### Next opportunities (remaining 1.95x overhead):
1. **Constant deduplication**: emitIntConstant already dedupes, but emitFloatConstant may not
2. **Dead instruction elimination**: IR may have unused instructions that emit ops
3. **Type dedup for int/uint**: int and uint are separate types in SPIR-V but many constants could share
4. **Reduce param var creation**: Only create OpVariable for params that are actually written to
5. **Function inlining**: Small helper functions (saturate, etc.) could be inlined to reduce call overhead
