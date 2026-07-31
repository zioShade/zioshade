# Arbitrary-SPIR-V regression corpus (e54.4)

Real SPIR-V binaries that exercise zioshade's backends on **arbitrary / external input**
(the output of glslang / spirv-opt / spirv-reduce), not zioshade's own frontend. Each file
is a minimal repro for a bug class found by
[`tools/spv_input_validity_sweep.sh`](../../tools/spv_input_validity_sweep.sh). All pass
`spirv-val` (the point is that zioshade still emits output the downstream reference
compiler rejects on valid input).

Run the sweep:

```bash
just spv-validity
# or: tools/spv_input_validity_sweep.sh tests/arbitrary_spirv
```

| File | Producer | Stage | Bug class (beads) |
|---|---|---|---|
| `temp_0012.spv` | spirv-reduce | Fragment | `OpUndef` values used in control flow but never declared (`v5`/`v6`) -> undeclared identifier in GLSL/WGSL/MSL. spirv-cross zero-inits. |
| `vert.spv` | glslang | Vertex | Output interface variable (`_entryPointOutput_gl_Position`) used but its declaration dropped. |
| `comp.spv` | glslang | Compute | Compute-resource decoration mis-emitted: stray `@` token in GLSL, invalid `@data` attribute in WGSL. |

These are the gate's fixtures: a fix for a class must turn its file(s) from INVALID to valid
(spirv-cross-discriminated for MSL/HLSL) in the sweep. A file is intentionally kept here
until its class is fixed, after which it stays as a permanent regression guard.
