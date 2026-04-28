# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance, our_bound=7520 vs ref_bound=10159 (0.74x)

### Metrics progress:
| Iteration | our_bound | ref_bound | overhead | our_vars | ref_vars |
|-----------|-----------|-----------|----------|----------|----------|
| Baseline  | 29142     | 10159     | 2.87x    | 6782     | 1010     |
| ID waste fix | 10015 | 10159     | 0.99x    | 879      | 1010     |
| Const dedup | 9755   | 10159     | 0.96x    | 884      | 1010     |
| SSA optimization | 8905 | 10159   | 0.88x    | 642      | 1010     |
| Two-buffer codegen | 7685 | 10159  | 0.76x    | 642      | 1010     |
| Full two-buffer + DCE | 7520 | 10159 | 0.74x | 642 | 1010 |

### Session summary (this session):
- Started at: our_bound=10042 (0.99x glslang)
- Ended at: our_bound=7520 (0.74x glslang)
- **Reduction: -2522 IDs (-25.1%)**
- Conformance: 197/197 maintained throughout

### Key optimizations applied:
1. **Constant dedup in semantic analysis** (-287 IDs)
2. **SSA variable optimization** (-420 IDs) — skip OpVariable/OpStore for initialized simple-type locals
3. **SSA ID reuse** (-234 IDs) — reuse init_value as ir_id instead of allocating separate ID
4. **Two-buffer codegen** (-504 IDs) — emit types on-demand during function codegen
5. **Named type filtering** (-52 IDs) — only emit referenced named types
6. **Storage class dedup** (-252 IDs) — iterate unique storage classes instead of all globals
7. **Pre-scan reduction** (-157 IDs) — remove struct member and access_chain pre-emission
8. **Dead code elimination** (-7 IDs) — skip statements after return

### Remaining opportunities (diminishing returns):
1. **Function inlining**: We emit 8 functions vs glslang's 3 for ocean.vert. glslang inlines
   saturate/ComputeFogFactor/ApplyFog/ApplyLighting/ApplySpecular into main. This accounts
   for ~85 IDs per shader. Would need call graph analysis + heuristic inlining.
2. **Store-load forwarding**: Forward values for variables with single store.
   Would eliminate more OpStore+OpLoad pairs beyond current SSA optimization.
3. **Dead code elimination in nested blocks**: Current DCE only works at top-level
   function body. If/else branches and loops may have dead code after return.

### Architectural notes:
- The two-buffer approach (type_section) is the single biggest enabler
- Without it, we had to pre-emit ALL possible pointer types "just in case"
- With it, types are emitted on-demand and spliced before functions
- The bound is 74% of glslang, meaning our output is SMALLER (missing features)
- The "overhead" is actually UNDERHEAD — we produce less code than glslang
