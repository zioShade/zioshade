# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance, our_bound=8367 vs ref_bound=10159 (0.82x)

### Metrics progress:
| Iteration | our_bound | ref_bound | overhead | our_vars | ref_vars |
|-----------|-----------|-----------|----------|----------|----------|
| Baseline  | 29142     | 10159     | 2.87x    | 6782     | 1010     |
| ID waste fix | 10015 | 10159     | 0.99x    | 879      | 1010     |
| Const dedup | 9755   | 10159     | 0.96x    | 884      | 1010     |
| Pointer type fix | 9325 | 10159   | 0.92x    | 884      | 1010     |
| SSA optimization | 8905 | 10159   | 0.88x    | 642      | 1010     |
| SSA ID reuse + named type filter + SC dedup | 8367 | 10159 | 0.82x | 642 | 1010 |

### Architecture limitation: types must be emitted before functions
The codegen emits SPIR-V sequentially. Types emitted during function codegen
violate SPIR-V layout rules. The pre-scan in emitTypesAndConstants eagerly
emits pointer types for ALL possible storage classes, creating ~18 unused
pointer types per shader.

**Two-buffer refactor would fix this** but is complex:
- Add type_section buffer for types/constants during function codegen
- Splice type_section before functions in final assembly
- Would eliminate ~18 unused pointer types × 166 shaders = ~3000 IDs

### Opportunities (diminishing returns on bound reduction):
1. **Two-buffer codegen**: As described above. Most impactful remaining optimization.
2. **Store-load forwarding**: Track variables with single store, forward value to loads.
   Would eliminate more OpStore+OpLoad pairs beyond current SSA optimization.
3. **Dead instruction elimination**: Remove instructions whose results are never used.

### Opportunities (would INCREASE bound toward glslang):
4. **More complete texture ops**: image-query.desktop.frag 6/28 OpImageQuery ops
5. **Proper function call semantics**: Pass structs by pointer for out/inout params
6. **Row-major matrix support**: Some shaders need explicit RowMajor layout
7. **Struct SSA**: Allow struct types to be SSA'd when never member-accessed

### Per-shader analysis:
- ocean.vert: our=473 ref=325 (1.45x) — 18 unused pointer types, 8 OpTypeFunction vs 3
- ground.vert: similar pattern
- Most overhead is from pre-emitted pointer types for unused storage classes
