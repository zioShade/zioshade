# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance, our_bound=7685 vs ref_bound=10159 (0.76x)

### Metrics progress:
| Iteration | our_bound | ref_bound | overhead | our_vars | ref_vars |
|-----------|-----------|-----------|----------|----------|----------|
| Baseline  | 29142     | 10159     | 2.87x    | 6782     | 1010     |
| ID waste fix | 10015 | 10159     | 0.99x    | 879      | 1010     |
| Const dedup | 9755   | 10159     | 0.96x    | 884      | 1010     |
| SSA optimization | 8905 | 10159   | 0.88x    | 642      | 1010     |
| Two-buffer codegen | 7685 | 10159  | 0.76x    | 642      | 1010     |

### Key achievement: Two-buffer codegen eliminates unused pointer types
- Added type_section buffer for types emitted during function codegen
- Spliced before functions in final assembly
- Removed eager pre-scan of access_chain pointer types and struct member types
- our_bound dropped from 8367→7685 (-6.8%)

### Remaining optimizations (diminishing returns):
1. **Remove more pre-scan emissions**: The pre-scan still emits types for constants,
   ensureType calls, etc. that could be emitted on-demand via two-buffer.
2. **Store-load forwarding**: Forward values for variables with single store.
3. **Dead instruction elimination**: Remove instructions with unused results.
4. **Reduce OpTypeFunction count**: We emit 8 vs glslang's 3 for ocean.vert.

### Opportunities (would INCREASE bound toward glslang):
5. **More complete texture ops**: image-query.desktop.frag 6/28 OpImageQuery ops
6. **Proper out/inout param pointers**: Pass by pointer in OpTypeFunction
