# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance, SPIR-V output ~glslang parity (0.92x)

### Metrics progress:
| Iteration | our_bound | ref_bound | overhead | our_vars | ref_vars |
|-----------|-----------|-----------|----------|----------|----------|
| Baseline  | 29142     | 10159     | 2.87x    | 6782     | 1010     |
| ID waste fix | 10015 | 10159     | 0.99x ✅ | 879      | 1010     |
| Image query fix | 10044 | 10159 | 0.99x    | 884      | 1010     |
| Const dedup | 9755   | 10159     | 0.96x    | 884      | 1010     |
| Pointer type fix | 9325 | 10159   | 0.92x    | 884      | 1010     |

### Key insight: bound BELOW glslang means missing functionality
- our_vars=884 vs ref_vars=1010: We're creating fewer variables than glslang
- But per-shader, we create MORE function-scoped variables (48 vs 25 for ocean.vert)
- The lower total is because we don't implement all features

### Opportunities for bound reduction (store-load elimination):
1. **SSA value forwarding for var_decls**: When a local variable is initialized once
   and only read, forward the init value directly instead of store+load.
   This would eliminate ~20 OpVariables per shader + matching OpStore/OpLoad pairs.
   Requires tracking stores/loads per variable ID.
2. **Dead variable elimination**: If a local variable is stored but never loaded,
   remove both the store and the variable declaration.
3. **Avoid creating local vars for simple scalar temporaries**:
   `float x = expr;` could be SSA value if x is never reassigned.

### Opportunities for bound increase (functional completeness):
4. **Add missing image types**: Already done (image1D/3D/Cube/Array variants committed)
5. **More complete texture ops**: image-query.desktop.frag generates 6/28 OpImageQuery ops
6. **Proper sampler_cube_array (non-shadow)**: Needed for cube array operations

### Per-shader analysis (biggest overhead):
- ground.vert: our=591 ref=277 (2.1x) — 59 vs 33 vars, many float temporaries
- ocean.vert: our=637 ref=325 (2.0x) — 60 vs 36 vars, many float temporaries
- ground.frag: our=349 ref=147 (2.4x) — 47 vs 24 vars

### Optimization (minor, diminishing returns):
7. **Per-shader bound reduction**: Some shaders still 1.04x glslang (1 extra ID)
8. **OpVariable count**: 884 vs 1010 — some shaders may need more variables for correctness
