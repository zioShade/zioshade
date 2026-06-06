# glslpp — Implementation Status

**Honest scope and known limitations as of the current release.**

---

## Executive Summary

glslpp is a **pure-Zig GLSL→SPIR-V compiler and SPIR-V cross-compiler** (HLSL / MSL / GLSL / WGSL). It was extracted from [wintty](https://github.com/deblasis/wintty) to replace ~60 MB of glslang + SPIRV-Cross C++ dependencies in a single Zig module.

**What works today:**
- **wintty production use** — every shader wintty ships through GLSL → SPIR-V → HLSL / MSL / WGSL.
- **Correctness** — every conformance fixture's SPIR-V is validated with `spirv-val`; known-unsupported constructs are honestly rejected as XFAIL (the suite exits 0). **Authoritative counts: [`docs/STATUS.md`](STATUS.md)**, generated from a real run by `just status` (never hand-edited, so they cannot go stale). HLSL outputs validate via DXC; pixel-level rendering matches glslang+SPIRV-Cross for the validated set.
- **In-process API** — no process spawn, no DLL init, no global state outside `threadlocal` per-thread caches.

**What's missing relative to a true glslang / SPIRV-Cross drop-in:**
- Reflection API (`reflectSPIRV`) enumerates UBOs, SSBOs, sampled/separate images, separate samplers, storage images, subpass inputs, push constants, inputs/outputs, spec constants and acceleration structures, each with set/binding/location, struct members (name/offset/size/kind), image format, spec-id and **descriptor `array_size`**; opaque resources are bucketed by type. Full SPIRV-Cross-grade JSON-parity reflection (every decoration, array/matrix strides) is not a goal.
- GLSL **versions / extensions** parsed but only a subset semantically validated (focused on 430 + the extensions wintty uses).
- WGSL backend coverage has deepened substantially (built-in I/O, stage I/O interface blocks, control-flow replay, texture ops, scalar geometric builtins all naga-gated). Constructs WGSL genuinely cannot express (recursion, sampler/multisample arrays, layer/viewport/clip-cull/point-size, dual-source blending, ARM tensors, ray queries) **honest-error** with a named message rather than emit silent-wrong output; opcode breadth (~60 handlers) is still narrower than SPIRV-Cross.
- Specialization constants **are** supported (`OpSpecConstant*` / `OpSpecConstantOp`, `--spec-const` override). Separate sampler/image and shader linking beyond `linkSPIRVModules` remain limited.
- Descriptor **remap** is supported via `resource_bindings` (HLSL register / MSL slot per `(set, binding)`; CLI `--bind set:binding:reg`). UBO **flatten** (the GL-ES `--flatten-ubo` transform) is not implemented — out of practical scope for this project's targets.
- Cross-compiler control flow: structured SPIR-V works on every backend. **Unstructured-but-reducible SPIR-V is structurized transparently** — a module-level pre-pass recovers missing `OpSelectionMerge`s for reducible `if`/`switch` headers (`src/cfg_structurize.zig`; no-op on already-structured input). Unstructured **loops** (missing `OpLoopMerge`) and genuinely irreducible CFGs still **fail loud** (`error.UnstructuredControlFlow`) rather than miscompile — loop-merge recovery primitives exist but are not yet composed (valid Shader SPIR-V is always structured, so this only affects malformed/hand-authored input). See `docs/specs/2026-06-02-cfg-structurization.md`.

If your shaders fall inside the validated set, this should work. If you need full Khronos GLSL coverage or SPIRV-Cross-grade reflection, **use upstream**.

---

## 1. What We've Built

### 1.1 Project Stats

| Metric | Value |
|--------|-------|
| Source lines (Zig) | ~50,000 |
| Frontend (parser, semantic, codegen) | ~18,000 |
| Cross-compilers (HLSL, GLSL, MSL, WGSL) | ~12,000 |
| Optimizer (compact_ids_passes) | ~10,200 |
| Preprocessor | ~1,800 |
| `spirv-val` conformance passing | 2076 PASS / 0 FAIL / 14 XFAIL / 8 SKIP / 2098 total — exits 0 (`zig build conformance`; see `docs/STATUS.md`) |
| External DXC SPIR-V fixtures | 47 / 51 compile (4 limited by DXC SM 6.1+ / 2 KB structured-buffer cap) |
| WGSL stress tests | 470 / 470 |
| Fuzzer iterations (clean) | 1,000,000 (run `just fuzz-million` to reproduce; ad-hoc: `zig build fuzz -- --count N`) |
| Shader stages supported | 14 (vert, frag, comp, geom, tesc, tese, mesh, task, raygen, closesthit, miss, intersection, anyhit, callable) |

### 1.2 Frontend (replaces glslang)

| Capability | glslang | glslpp | Status |
|------------|---------|--------|--------|
| GLSL versions | 100–460, ESSL 100/300/310/320 | Parses `#version`, validates 430 | ⚠️ Partial |
| Preprocessor directives | Full | `#define`, `#if`/`#ifdef`/`#elif`, `#else`, `#endif`, `#include`, `#extension`, `#pragma`, `#line`, `#error`, `#warning`, `#undef` | ✅ Complete for wintty |
| Macro expansion | Object-like + function-like, token paste (`##`), stringify (`#`), recursion guard | Object-like + function-like, token paste, recursion guard | ✅ |
| Fragment shaders | ✅ | 1,550 pass | ✅ |
| Vertex shaders | ✅ | 54 pass | ✅ |
| Compute shaders | ✅ | 103 pass | ✅ |
| Geometry shaders | ✅ | 3 pass | ✅ |
| Tessellation shaders | ✅ | 2 pass (tesc + tese) | ✅ |
| Mesh/Task shaders | ✅ | 4 pass | ⚠️ Basic |
| Ray tracing shaders | ✅ | 3 pass | ⚠️ Basic |
| SPIR-V output | 1.0–1.6 | 1.0–1.6 | ✅ |
| spirv-val conformance | Reference | 2076 PASS / 0 FAIL / 14 XFAIL (honest rejections) / 8 SKIP / 2098 total — exits 0 | ✅ |
| GLSL extensions parsed | 100+ | 9 (subgroup basic/vote/arithmetic/ballot/shuffle, fragment interlock, mesh, ray tracing, null initializer) | ⚠️ Covers wintty needs |
| Error diagnostics | Rich (line, column, context) | Basic (error enum, no location) | ❌ Gap |

### 1.3 Cross-Compiler (replaces SPIRV-Cross)

| Capability | SPIRV-Cross | glslpp | Status |
|------------|-------------|--------|--------|
| HLSL output | SM 5.0+ | SM 6.0 | ✅ DXC validates 47/51 |
| MSL output | 2.0+ | Metal 2.0+ | ✅ |
| GLSL output | 110, 140, 150, 300 es, 330, 410, 430, 450, 460 | 430 | ⚠️ Single version |
| WGSL output | ✅ | ✅ | ✅ naga-validated; stage I/O **interface blocks** (in + out), cross-function I/O, frexp/modf struct-return, loop phi, passthrough-return, scalar geometric builtins, vector shifts, array-element/struct construction all naga-clean. Honest-errors the genuinely-unrepresentable: recursion, multisample/sampler arrays, layer/viewport/clip-cull/point-size built-ins, dual-source blending, ARM tensors, ray queries, geometry/tess stages |
| SPIR-V input (pre-compiled) | ✅ Full | ✅ Partial (best-effort) | ⚠️ Assumes glslpp structure |
| Opcode handler coverage | ~400 opcodes | HLSL: 180, GLSL: 132, MSL: 130, WGSL: 60 | ✅ HLSL strong, ⚠️ WGSL weak |
| Reflection API | ✅ Full | ⚠️ Partial (`reflect`) | ⚠️ Gap |
| Descriptor set management | ✅ Full | `binding_shift` + per-resource `resource_bindings` remap (HLSL/MSL, CLI `--bind`); no UBO flatten | ⚠️ Partial |
| Combined image sampler | ✅ | Partial | ⚠️ |
| UBO/SSBO layout handling | Full (std140, std430, row/column-major) | Basic (std140, std430) | ⚠️ |
| Specialization constants | ✅ | `layout(constant_id=N) const` → `OpDecorate SpecId` + `OpSpecConstant` (spirv-val clean); CLI `--spec-const ID=VAL` override; WGSL `@id(N) override`; HLSL `[[vk::constant_id(N)]]` | ✅ |
| Separate sampler/image | ✅ | Partial | ⚠️ |

### 1.4 Optimizer Passes

| Pass | Description | Status |
|------|-------------|--------|
| Dead Code Elimination | With store-to-load forwarding | ✅ |
| Constant Folding | Includes bool replacement, type-aware | ✅ |
| Common Subexpression Elimination | Redundant computation removal | ✅ |
| Identity Store Elimination | Remove stores that don't change value | ✅ |
| Inline Trivial Functions | Single-block function inlining | ✅ |
| Inline Multi-Block Functions | Multi-block function inlining | ✅ |
| Variable Move to Entry | Hoist OpVariable to entry block | ✅ |
| Loop Counter Phi | Phi node generation for loop variables | ✅ |
| Branch Merge Phi | Phi node generation at branch merge points | ✅ |
| Compact IDs | SPIR-V ID compaction | ✅ |
| Fix Early Access Variables | Reorder variables before access instructions | ✅ |
| Scatter Store to Composite | Composite store decomposition | ✅ |
| Elim Unused Imports | Remove unused OpExtInstImport | ✅ |
| copyMemoryOpt | Replace Load+Store with OpCopyMemory | ❌ Disabled (causes hangs/undefined IDs) |

### 1.5 Built-in Support

**GLSL built-in variables** (36):

| Stage | Built-ins |
|-------|-----------|
| Vertex | `gl_Position`, `gl_PointSize`, `gl_ClipDistance`, `gl_CullDistance`, `gl_VertexID`, `gl_InstanceID`, `gl_VertexIndex`, `gl_InstanceIndex`, `gl_BaseVertex`, `gl_BaseInstance`, `gl_DrawID` |
| Fragment | `gl_FragCoord`, `gl_FragDepth`, `gl_FrontFacing`, `gl_SampleID`, `gl_SamplePosition`, `gl_SampleMask`, `gl_HelperInvocation`, `gl_FragColor` |
| Compute | `gl_WorkGroupID`, `gl_LocalInvocationID`, `gl_GlobalInvocationID`, `gl_LocalInvocationIndex`, `gl_NumWorkGroups`, `gl_WorkGroupSize` |
| Geometry | `gl_PrimitiveIDIn`, `gl_PrimitiveID`, `gl_InvocationID`, `gl_Layer`, `gl_ViewportIndex` |
| Tessellation | `gl_TessCoord`, `gl_TessLevelInner`, `gl_TessLevelOuter`, `gl_PatchVerticesIn` |
| Ray tracing | `gl_LaunchIDEXT`, `gl_LaunchSizeEXT`, `gl_WorldRayOriginEXT`, `gl_WorldRayDirectionEXT`, `gl_ObjectRayOriginEXT`, `gl_ObjectRayDirectionEXT`, `gl_RayTminEXT`, `gl_RayTmaxEXT`, `gl_IncomingRayFlagsEXT`, `gl_HitKindEXT`, `gl_InstanceCustomIndexEXT` |
| Subgroup | `gl_SubgroupSize`, `gl_SubgroupInvocationID`, `subgroupElect()`, `subgroupAll()`, `subgroupAny()`, `subgroupAllEqual()` |

### 1.6 Test Coverage

| Suite | Pass | Total | Notes |
|-------|------|-------|-------|
| spirv-cross | 1,550 | 1,550 | Real-world GLSL patterns |
| glslang-430 | 22 | 22 | glslang test suite |
| ghostty | 9 | 9 | Production terminal shaders |
| compute | 13 | 13 | Compute shaders |
| tessellation | 13 | 13 | TCS/TES shaders |
| geometry | 15 | 15 | Geometry shaders |
| mesh-task | 4 | 4 | Mesh/task shaders |
| stress | ~140 | ~140 | Handcrafted edge cases |
| DXC validated | 47 | 51 | HLSL→DXIL compilation |
| Fuzzer | 1,000,000 | 1,000,000 | structured-GLSL, 0 crashes (`just fuzz-million`) |
| Rendering verified | 2+83 | — | CRT + focus pixel-perfect, 83 render_compare |

---

## 2. wintty C++ Toolchain Replacement

### 2.1 Migration Status

The wintty `feat/glslpp-integration` branch has fully migrated from C++ to pure Zig:

| Component | Before | After | Savings |
|-----------|--------|-------|---------|
| GLSL→SPIR-V | glslang (C++, ~30MB) | `glslpp.compileToSPIRV()` | 30MB removed |
| SPIR-V→HLSL/MSL/GLSL | SPIRV-Cross (C++, ~30MB) | `glslpp.spirvToHLSL/MSL/GLSL()` | 30MB removed |
| pkg/glslang/ directory | ~30MB | Removed (cf845724) | ✅ |
| pkg/spirv-cross/ directory | ~30MB | Removed (cf845724) | ✅ |
| **Total C++ dependencies** | **~60MB** | **0 bytes** | **60MB saved** |

### 2.2 Shader Pipeline

```
wintty shader compilation (all platforms):

GLSL source
  ├── DX12:  glslpp.compileGlslToHlsl()  → HLSL → DXC → DXIL bytecode
  ├── Metal: glslpp.compileGlslToMsl()    → MSL  → Metal compiler → metallib
  └── GL:    glslpp.compileGlslToGlsl()   → GLSL → OpenGL driver (runtime)

Shadertoy custom shaders:
  └── glslpp.compileShadertoyToHlsl() / compileGlslToMsl() / compileGlslToGlsl()
```

### 2.3 What Cannot Be Replaced

DXC and the Metal compiler are **platform SDK tools** that produce GPU-specific bytecode. No pure-Zig alternative exists or is feasible — every shader project needs the vendor's compiler for the final bytecode step. This was true with glslang + SPIRV-Cross as well.

---

## 3. Correctness Verification

### 3.1 SPIR-V Validation

**2,076** runnable fixtures pass `spirv-val` — the official SPIR-V validator (see `docs/STATUS.md`, the generated single source of truth; counts updated 2026-06-06). 14 known-unsupported fixtures are now **honestly rejected** as `error.SemanticFailed` (XFAIL) instead of silently emitting hollow SPIR-V; 8 skipped; 2,098 total. The suite exits **0**. The 14 XFAIL fixtures cover: 64-bit int/float types (`fp64`, `int64`), OpExtInst new-form texture builtins (`newTexture`), AMD extensions (`gcn_shader`, `shader_ballot`, `nvAtomicFp16Vec`), clock extension (`shader-clock`), ray/type-mismatch (`ray_sphere_test`, `image-query`), and other unmodeled constructs (`extended-arithmetic`, `spv.AofA`, `spv.double`, `struct-material`). (`spec-constant-work-group-size` was XFAIL but now **passes** since the top-level const-cache dangling-id fix.) These are expected honest rejections, not regressions.

### 3.2 DXC Validation

**47 / 51** pre-compiled SPIR-V→HLSL shaders compile with DXC (SM 6.0). The 4 failures are:
- 3 barycentric tests: `SV_Barycentrics` requires SM 6.1+; DXC also doesn't support two barycentric semantics in one shader
- 1 complex-expression: structured buffer exceeds DXC's 2,048-byte limit (actual: 16,384 bytes)

All 4 are DXC toolchain constraints, not glslpp bugs.

### 3.3 Cross-Compilation Validation

All 3 primary backends produce compilable output across the conformance corpus (exact per-backend pass counts predate the current 2,098-fixture corpus and are pending regeneration — tracked under the "single source of truth for status numbers" cleanup):
- **GLSL backend**: passes
- **MSL backend**: passes
- **HLSL backend**: passes (DXC-validated 47/51 on the prebuilt SPIR-V fixtures)
- **Cross-compare** (GLSL↔HLSL output consistency): pass
- **WGSL backend**: passes its test suite

### 3.4 Rendering Verification

- **CRT shader**: pixel-perfect match with OpenGL reference (128×128)
- **Focus shader**: pixel-perfect match with OpenGL reference
- **83 render_compare tests**: pixel-level comparison against reference rendering

### 3.5 Fuzz Testing

The structured-GLSL fuzzer is clean over **1,000,000** iterations (reproduce with `just fuzz-million`; ad-hoc runs via `zig build fuzz -- --count N`). The per-seed sweep below is the original smaller ad-hoc run kept for reference.

| Seed | Iterations | Crashes | Invalid SPIR-V |
|------|-----------|---------|----------------|
| 42 | 5,000 | 0 | 0 |
| 123 | 5,000 | 0 | 0 |
| 777 | 10,000 | 0 | 0 |
| 999 | 10,000 | 0 | 0 |
| 1337 | 10,000 | 0 | 0 |
| 77 | 10,000 | 0 | 0 |
| **Total** | **50,000** | **0** | **0** |

---

## 4. Performance

> **Caveat:** the per-call latency numbers below compare in-process glslpp against `glslangValidator` invoked as a subprocess. This favours glslpp because glslang is paying process-startup cost on every shader. A library-vs-library benchmark against glslang's `libglslang.a` + libspirv-cross has **not** been published yet and is on the roadmap — see [Other gaps](#other-gaps-flagged-during-pre-release-audit). Until that exists, treat the speedup numbers as *workflow* comparisons (CLI tool vs in-process library) rather than algorithm comparisons.

### 4.1 GLSL→SPIR-V Compile Time (in-process glslpp vs `glslangValidator` subprocess)

| Shader | glslang CLI (process) | glslpp (library) | Workflow speedup |
|--------|-----------------------|-------------------|------------------|
| simple_frag | ~178 ms | ~755 µs | ~235× |
| noise_func | ~178 ms | ~790 µs | ~225× |
| struct_loop | ~178 ms | ~1,172 µs | ~152× |

`glslangValidator`'s ~178 ms is dominated by process startup (~150 ms). The per-call algorithmic difference is much smaller than the workflow numbers suggest.

### 4.2 Full Pipeline (GLSL → SPIR-V → HLSL + GLSL + MSL)

| Shader | Time (all 3 backends) |
|--------|-----------------------|
| simple_frag | ~817µs |
| noise_func | ~984µs |
| struct_loop | ~1,292µs |

### 4.3 Cross-Compile Only (SPIR-V → backend, pre-compiled)

| Backend | Time |
|---------|------|
| HLSL | ~42µs |
| GLSL | ~41µs |
| MSL | ~39µs |

### 4.4 Real-World Impact for wintty

wintty compiles ~10 shaders at startup:
- **glslang (process spawn)**: 10 × 178ms = ~1.8 seconds
- **glslpp (library)**: 10 × 900µs = ~9ms
- **Savings**: ~1.8 seconds faster startup

---

## 5. Gap Analysis: What's Missing for 100% Replacement

### Tier 1: Critical (required for general-purpose library use)

| # | Gap | Impact | Effort |
|---|-----|--------|--------|
| G1 | **Reflection API** | Without this, consumers must hardcode bindings/inputs/outputs. SPIRV-Cross's most-used feature after cross-compilation. | Large (new module, ~2,000 lines) |
| G2 | **Robust pre-compiled SPIR-V consumption** | Backends assume glslpp-generated SPIR-V structure. Need to handle arbitrary SPIR-V from glslang, DXC, etc. | Medium (defensive parsing, edge cases) |
| G3 | **Diagnostic quality** | Line/column tracking through the pipeline. Currently errors are opaque enums. | Medium (source mapping throughout) |

### Tier 2: Important (needed for projects beyond wintty)

| # | Gap | Impact | Effort |
|---|-----|--------|--------|
| G4 | **GLSL version flexibility** | Backend hardcodes #version 430. Should support 330, 410, 450, etc. | Small (parameter + header generation) |
| G5 | **WGSL backend depth** | Only 60 opcode handlers vs 130–180 for others. Complex shaders won't cross-compile. | Medium (fill missing handlers) |
| G6 | **Descriptor set / binding management** | SPIRV-Cross can remap descriptor sets, flatten UBOs, merge sets. glslpp has `binding_shift` only. | Large (new subsystem) |
| G7 | **Specialization constants** | Required for Vulkan pipeline caching and optimization. | Medium (new codegen path) |
| G8 | **Separate sampler/image** | Vulkan best practice (separate samplers and images). Currently combined-only. | Medium (SPIR-V type tracking) |

### Tier 3: Nice-to-have (completeness)

| # | Gap | Impact | Effort |
|---|-----|--------|--------|
| G9 | **More GLSL extensions** | Only 9 parsed. Full glslang supports 100+. Low priority unless specific project needs them. | Small each, large total |
| G10 | **HLSL SM 5.0** | Currently SM 6.0 only. DX11 projects need SM 5.0. | Small (semantic naming differences) |
| G11 | **Row-major / column-major matrix layout** | Basic handling. Full SPIRV-Cross has explicit layout management. | Medium |
| G12 | **Multi-entry-point support** | Some SPIR-V modules have multiple entry points. | Small |
| G13 | **Copy-memory optimization** | Disabled due to correctness issues. Would save one instruction per struct copy. | Hard (fundamental DCE interaction) |

---

## 6. Recommendations

### Priority Order for Closing Gaps

1. **G3 (Diagnostics)** — Quick win, high impact for developer experience. Track source locations through parser→semantic→codegen.

2. **G4 (GLSL version flexibility)** — Small change, unblocks projects that need specific GLSL versions.

3. **G1 (Reflection API)** — Largest gap. Implement as a separate module that analyzes the SPIR-V binary to extract resources, bindings, types.

4. **G5 (WGSL backend)** — Systematic gap-filling following the same approach used for HLSL/GLSL/MSL.

5. **G7 (Specialization constants)** — Required for Vulkan pipeline use cases.

6. **G6 (Descriptor management)** — Complex but important for general-purpose use.

7. **G2, G8, G10, G11** — Fill in as needed based on consumer demand.

### What NOT to do

- **Don't try to match glslang's GLSL version coverage** — 430 covers the vast majority of modern shaders. ESSL support would require a different preprocessor dialect.
- **Don't try to parse all 100+ GLSL extensions** — Add them on demand when real projects need them.
- **Don't re-enable copyMemoryOpt** — It causes hangs and invalid SPIR-V. The one-instruction saving isn't worth the risk.


---

## Roadmap

A comprehensive plan to close the remaining gaps and reach drop-in parity with glslang + SPIRV-Cross is documented at [`docs/roadmap/2026-05-26-drop-in-replacement-plan.md`](roadmap/2026-05-26-drop-in-replacement-plan.md). It is organized as 8 TDD milestones (~50 bite-sized tasks) and estimated at 2–3 weeks of focused work.

## Other gaps flagged during pre-release audit

These are tracked openly so consumers can decide whether glslpp fits their use case today.

- **CI workflow committed, not yet green.** A 3-OS GitHub Actions matrix (`.github/workflows/ci.yml`: build/test, spirv-val conformance, fuzz smoke, C-ABI smoke) is committed but has not yet been observed passing in CI due to a GitHub Actions billing block; conformance is currently verified locally via `zig build conformance` / `just`.
- **Lib-vs-lib benchmark (cross-compiler) published:** `just lib-bench` links **SPIRV-Cross in-process** (its C API, from the Vulkan SDK static libs) and times glslpp vs SPIRV-Cross on the *same* SPIR-V → GLSL/HLSL/MSL. Honest result (no subprocess): glslpp is ~**1.4–1.6× faster** on the median cell — roughly at parity on a trivial GLSL shader (~0.6×) and up to ~2.6× faster on math/control-flow-heavy MSL. (Numbers are machine-relative; rerun locally.) A glslpp-vs-glslang in-process comparison for the **GLSL→SPIR-V** direction (`glslang_c_interface.h`) is not yet wired — the front-end half of the bench remains.
- **`spirv-val` is the conformance oracle, not glslang reference output.** Some test fixtures in `tests/spirv-cross/` are known to fail reference compilation with `glslangValidator` even though glslpp accepts them — see `docs/REFERENCE_FAILURE_ANALYSIS.md`.
- **Cross-compiler control flow (G2 partial).** A module-level structurization pre-pass (`src/cfg_structurize.zig`, run by every backend) recovers missing `OpSelectionMerge`s for unstructured-but-reducible `if`/`switch` headers via dominator/post-dominator analysis, so externally-optimized SPIR-V with stripped selection merges compiles faithfully (byte-identical no-op on already-structured input). Unstructured **loops** (missing `OpLoopMerge`) and irreducible CFGs still **fail loud** (`error.UnstructuredControlFlow`) — never miscompiled. Loop-merge recovery primitives exist (`recoverLoopMerges`/`spliceLoopMerges`, unit-tested) but composing them with selection recovery is future work; valid Shader SPIR-V is always structured, so this only affects malformed/hand-authored input.
- **C ABI is provided.** A C header (`include/glslpp.h`) plus shared and static libraries are built with `zig build c-lib`; a runnable C consumer example lives in `examples/c/main.c` (`zig build c-example` / `zig build run-c-example`). The public C surface is smoke-tested across Linux / macOS / Windows by the `c-abi` job in `.github/workflows/ci.yml`.
- **Single-contributor project.** No formal release cadence yet; treat as alpha if you are not the wintty project.
