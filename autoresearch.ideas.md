# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance, our_bound=8619 vs ref_bound=10159 (0.85x)

### Metrics progress:
| Iteration | our_bound | ref_bound | overhead | our_vars | ref_vars |
|-----------|-----------|-----------|----------|----------|----------|
| Baseline  | 29142     | 10159     | 2.87x    | 6782     | 1010     |
| ID waste fix | 10015 | 10159     | 0.99x    | 879      | 1010     |
| Const dedup | 9755   | 10159     | 0.96x    | 884      | 1010     |
| Pointer type fix | 9325 | 10159   | 0.92x    | 884      | 1010     |
| SSA optimization | 8905 | 10159   | 0.88x    | 642      | 1010     |
| SSA ID reuse | 8671   | 10159     | 0.85x    | 642      | 1010     |
| Named type filter | 8619 | 10159   | 0.85x    | 642      | 1010     |

### Key insight: our_bound is 85% of glslang — we're MISSING functionality
- our_vars=642 vs ref_vars=1010: We have 60% as many variables
- Per-shader we have FEWER vars (20 vs 36 for ocean.vert) AND lower bound
- The 18 unused types per shader (pre-emitted pointer types) add ~18 wasted IDs
- Store-load elimination (SSA) is working but only for scalar/vector/matrix

### Opportunities for bound reduction (diminishing returns):
1. **Two-buffer codegen**: Separate types section from functions section.
   This would let us only emit pointer types on-demand during function codegen,
   eliminating 18 unused pointer types per shader (~18 IDs × 166 shaders = ~3000 IDs).
   Requires refactoring codegen to buffer types separately.
2. **Lazy type emission**: Only emit types when first referenced by an instruction.
   Same as above but more granular.
3. **Eliminate more SSA overhead**: Extend SSA to cover more patterns.

### Opportunities for functional completeness (would INCREASE bound toward glslang):
4. **More complete texture ops**: image-query.desktop.frag generates 6/28 OpImageQuery ops
5. **Proper function call semantics**: Pass structs by value correctly
6. **Row-major matrix support**: Some shaders need explicit RowMajor layout

### Per-shader analysis (biggest overhead despite SSA):
- ground.vert: our=519 ref=277 (1.87x) — many unused pointer types pre-emitted
- ocean.vert: our=554 ref=325 (1.70x) — 18 unused types, extra OpTypeFunction
- ground.frag: our=245 ref=147 (1.67x) — same pattern

### Architecture note:
The codegen emits SPIR-V sequentially (header → caps → types → globals → functions).
This means types MUST be emitted before functions. The pre-scan in emitTypesAndConstants
eagerly emits pointer types "just in case" because they can't be retroactively inserted.
A two-buffer approach would fix this architectural limitation.
