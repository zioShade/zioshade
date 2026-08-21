# MSL contract diff vs spirv-cross: what a consumer must change to swap

Measured 2026-08-21 at `3b545714`. The Metal-side companion to
`ACCEPTANCE_PARITY.md`: same methodology (two-oracle differential), aimed at
the question a spirv-cross consumer asks — if my pipeline consumes
`spirv-cross --msl` output today, what changes when I feed the same SPIR-V
to `zioshade msl`?

## Method

- Input: the 898 shaders BOTH compilers accepted in the front-end parity
  run, compiled to SPIR-V by **glslang** (a neutral third producer — not
  zioshade's own front-end, so producer-specific shaping cannot bias either
  side).
- Oracles: `spirv-cross --msl` (defaults) and `zioshade msl` (defaults,
  MSL 2.1) on the SAME `.spv`.
- Consumer-visible facets extracted from each output: header block, entry
  name and signature (`main0`, `main0_in`/`main0_out`), stage-io struct
  field attributes, resource-binding table (`[[buffer/texture/sampler/
  attribute(N)]]`), with `spirv-cross --reflect` as binding ground truth.
- 834 of 898 compared (31 spirv-cross MSL failures + 33 zioshade MSL
  refusals dropped those files; see Refusals).

## Facet results

| facet | equal | notes |
|---|---:|---|
| header / preamble | content-identical | spirv-cross prepends a clang `#pragma` on some outputs; zioshade emits the plain `#include <metal_stdlib>` + `using namespace metal;` block |
| entry naming | 100% | both `main0`, both `main0_in` / `main0_out` structs |
| `stage_in` attributes | 823/834 | all 11 diffs: spirv-cross strips UNUSED varyings; zioshade preserves the declared interface |
| `stage_out` attributes | 830/834 | diffs: fragment `[[depth(greater)/[[depth(less)]]` layout qualifiers zioshade emits that spirv-cross defaults off, + field order (matched by attribute, not order, in Metal) |
| binding policy vs SPIR-V | z 830/834 1:1; sc 816/834 1:1 | see below |
| entry params | 164 identical; 581 differ | every inspected diff is zioshade ALWAYS emitting `float4 gl_FragCoord [[position]]` on fragments where spirv-cross adds it only when used — a valid, always-bindable extra input |

## Binding policy (the facet that touches the pipeline table)

zioshade maps MSL slots 1:1 from SPIR-V `(set, binding)` — a Vulkan-shaped
descriptor table survives the crossing unchanged — on 830/834. The 4 remaps
are Vulkan-legal same-slot collisions Metal cannot express (a UBO and an
SSBO both at `(set 0, binding 0)` get sequential buffer slots) and
same-slot UBO flattening (three same-slot UBOs merged into one constant
buffer). spirv-cross remaps 18/834 by its own sequential resequencing.

For the consumer: with spirv-cross you may already carry an
MSLResourceBinding table to undo its resequencing; with zioshade you can
delete it and use your Vulkan indices directly.

## Refusals (both tools have a set)

zioshade refused 33: dominated by `buffer_reference` / physical storage
buffers (documented honest-error: `UnsupportedPhysicalStorageBuffer`) and,
before this run's fixes, `OpLogicalEqual`/`OpLogicalNotEqual` (fixed in
#665). spirv-cross failed 31 (barycentric-khr, io-blocks, and its own
vendor-extension set). Neither direction is a correctness claim; both are
coverage.

## Bugs this run found (and fixed)

1. **Anonymous block instances emitted `device &` / `constant &`**
   (silent-wrong, exit 0): `buffer B { ... };` with no instance name
   carries `OpName ""` — present but empty — which passed the collectors'
   guards. Fixed in #665 with the UBO fallback chain (variable name →
   struct TYPE name → minted), published back so declaration, parameter
   and body references agree.
2. **`OpLogicalEqual` / `OpLogicalNotEqual` had no arm in the GLSL, HLSL
   and MSL backends** (WGSL had them): `p == q` / `p != q` on bools
   refused or left the result undefined. Fixed in #665.

Both were invisible to the repo's frontend-driven tests: zioshade's own
front-end never produces the empty-OpName shape, and the internal corpus
never spelled bool equality. The new tests drive glslang directly — the
same lesson as the include tests of #663: a pipeline tested only against
its own producer is blind to the shapes real producers emit.

## Switching-cost summary

Keep: entry names, stage-io struct shapes, attribute encodings — drop-in.
Change: nothing in code; keep your vertex descriptors COMPLETE (zioshade
does not strip unused attributes), expect the constant `[[position]]`
fragment input, and (if coming from spirv-cross resequencing) simplify
your binding table to Vulkan indices.

Rerun: two-oracle driver over the parity corpus, method above is the
contract.
