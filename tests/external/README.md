# tests/external/ — Real-world shader corpus

Curated shaders that exercise common Vulkan / WebGPU patterns end-to-end:
glslpp compile → reflect → cross-compile (WGSL / HLSL / MSL / GLSL).

Run with:

    mise exec -- zig build test-realworld

Each shader's expected pass mode is documented inline. Categories:

- **Compute**: SSBO read/write, atomics, shared memory.
- **Fragment**: textures, samplers, multi-render-target, builtins.
- **Vertex**: location-bound I/O, gl_Position, uniform blocks.
- **Mesh**: SetMeshOutputsEXT, EmitMeshTasksEXT (current glslpp limitation:
  HLSL mesh signature is M5.2 v1 placeholder; WGSL doesn't support mesh).
- **Ray tracing**: traceRayEXT, payload structs.

Sources:

- Hand-authored for this project (MIT OR Apache-2.0 dual-licensed, same as glslpp).
- Pattern inspiration from shader codes in glslang / spirv-cross test suites
  but **rewritten from scratch** to avoid license entanglement.

## Naga validation

If [`naga`](https://github.com/gfx-rs/wgpu/tree/trunk/naga) is on `PATH`
(e.g., `cargo install naga-cli`), the realworld runner pipes each emitted
WGSL through `naga --input-kind wgsl` as an external sanity check. If naga
isn't available, the runner still walks the corpus and reports glslpp-side
PASS/FAIL — it just skips the external validation step.

## Known limitations exercised by this corpus

These shaders intentionally pin known-buggy paths so they don't silently
start passing without a roadmap note:

- `06_minimal.vert` — HLSL backend doesn't yet emit a valid vertex entry
  signature (tracked as M5.0 in the roadmap). Expected to fail HLSL
  cross-compile.
- `08_ssbo_write.comp` — HLSL compute SSBO emit is known-buggy as of
  commit `c77f5452`. Expected to fail HLSL cross-compile; should still
  PASS SPIR-V + WGSL + MSL + GLSL.

The remaining shaders should compile cleanly across all backends.

## Current snapshot

See [`docs/realworld-corpus.md`](../../docs/realworld-corpus.md) for the
last recorded per-backend pass rate.
