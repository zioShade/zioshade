# glslpp — Implementation Status

**Honest scope and known limitations as of the current release.**

---

## Executive Summary

glslpp is a **pure-Zig GLSL→SPIR-V compiler and SPIR-V cross-compiler** (HLSL / MSL / GLSL / WGSL). It was extracted from [wintty](https://github.com/deblasis/wintty) to replace ~60 MB of glslang + SPIRV-Cross C++ dependencies in a single Zig module.

**What works today:**
- **wintty production use** — every shader wintty ships through GLSL → SPIR-V → HLSL / MSL / WGSL.
- **Correctness** — <!-- STATUS:conformance.pass -->2,080<!-- /STATUS --> / <!-- STATUS:conformance.runnable -->2,087<!-- /STATUS --> runnable fixtures pass `spirv-val` (<!-- STATUS:conformance.fail -->7<!-- /STATUS --> known feature-gap failures, not regressions); HLSL outputs validate via DXC; pixel-level rendering matches glslang+SPIRV-Cross for the validated set.
- **In-process API** — no process spawn, no DLL init, no global state outside `threadlocal` per-thread caches.

**What's missing relative to a true glslang / SPIRV-Cross drop-in:**
- Reflection API is **partial** (uniform / sampler enumeration; no full descriptor binding metadata).
- GLSL **versions / extensions** parsed but only a subset semantically validated (focused on 430 + the extensions wintty uses).
- WGSL backend has **shallow opcode coverage** vs SPIRV-Cross (~60 vs ~400 opcode handlers).
- **No specialization constants** (`OpSpecConstant*`), no separate sampler/image (`OpTypeSamplerImage`) lowering, no shader linking beyond `linkSPIRVModules`.
- Cross-compiler control flow currently requires `OpSelectionMerge` for `if` / `switch`; unstructured CFG emits an empty body with a `glslpp: unstructured branch` marker comment and a stderr warning.

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
| `spirv-val` conformance passing | <!-- STATUS:conformance.pass -->2,080<!-- /STATUS --> / <!-- STATUS:conformance.runnable -->2,087<!-- /STATUS --> runnable (<!-- STATUS:conformance.fail -->7<!-- /STATUS --> known feature-gap fails; `zig build conformance`) |
| External DXC SPIR-V fixtures | 47 / 51 compile (4 limited by DXC SM 6.1+ / 2 KB structured-buffer cap) |
| WGSL stress tests | 470 / 470 |
| Fuzzer iterations (clean, ad-hoc) | 50,000 (run `zig build fuzz -- --count 50000` to reproduce) |
| Shader stages supported | 14 (vert, frag, comp, geom, tesc, tese, mesh, task, raygen, closesthit, miss, intersection, anyhit, callable) |

### 1.2 Frontend (replaces glslang)

| Capability | glslang | glslpp | Status |
|------------|---------|--------|--------|
| GLSL versions | 100–460, ESSL 100/300/310/320 | Parses `#version`, validates 430 | ⚠️ Partial |
| Preprocessor directives | Full | `#define`, `#if`/`#ifdef`/`#elif`, `#else`, `#endif`, `#include`, `#extension`, `#pragma`, `#line`, `#error`, `#warning`, `#undef` | ✅ Complete for wintty |
| Macro expansion | Object-like + function-like, token paste (`##`), stringify (`#`), recursion guard | Object-like + function-like, token paste, recursion guard | ✅ |
| Fragment shaders | ✅ | see [STATUS.md](STATUS.md) | ✅ |
| Vertex shaders | ✅ | see [STATUS.md](STATUS.md) | ✅ |
| Compute shaders | ✅ | see [STATUS.md](STATUS.md) | ✅ |
| Geometry shaders | ✅ | see [STATUS.md](STATUS.md) | ✅ |
| Tessellation shaders | ✅ | see [STATUS.md](STATUS.md) | ✅ |
| Mesh/Task shaders | ✅ | 4 pass | ⚠️ Basic |
| Ray tracing shaders | ✅ | 3 pass | ⚠️ Basic |
| SPIR-V output | 1.0–1.6 | 1.0–1.6 | ✅ |
| spirv-val conformance | Reference | <!-- STATUS:conformance.pass -->2,080<!-- /STATUS -->/<!-- STATUS:conformance.runnable -->2,087<!-- /STATUS --> runnable pass (<!-- STATUS:conformance.fail -->7<!-- /STATUS --> feature-gap fails) | ✅ |
| GLSL extensions parsed | 100+ | 9 (subgroup basic/vote/arithmetic/ballot/shuffle, fragment interlock, mesh, ray tracing, null initializer) | ⚠️ Covers wintty needs |
| Error diagnostics | Rich (line, column, context) | Basic (error enum, no location) | ❌ Gap |

### 1.3 Cross-Compiler (replaces SPIRV-Cross)

| Capability | SPIRV-Cross | glslpp | Status |
|------------|-------------|--------|--------|
| HLSL output | SM 5.0+ | SM 6.0 | ✅ DXC validates 47/51 |
| MSL output | 2.0+ | Metal 2.0+ | ✅ |
| GLSL output | 110, 140, 150, 300 es, 330, 410, 430, 450, 460 | 430 | ⚠️ Single version |
| WGSL output | ✅ | ✅ | ⚠️ Shallow (60 opcode handlers) |
| SPIR-V input (pre-compiled) | ✅ Full | ✅ Partial (best-effort) | ⚠️ Assumes glslpp structure |
| Opcode handler coverage | ~400 opcodes | HLSL: 180, GLSL: 132, MSL: 130, WGSL: 60 | ✅ HLSL strong, ⚠️ WGSL weak |
| Reflection API | ✅ Full | ❌ None | ❌ Gap |
| Descriptor set management | ✅ Full | `binding_shift` only | ❌ Gap |
| Combined image sampler | ✅ | Partial | ⚠️ |
| UBO/SSBO layout handling | Full (std140, std430, row/column-major) | Basic (std140, std430) | ⚠️ |
| Specialization constants | ✅ | ❌ | ❌ Gap |
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

See **[docs/STATUS.md](STATUS.md)** for the live per-suite conformance breakdown and unit/HLSL totals (regenerated by `just update-status`).

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

**<!-- STATUS:conformance.pass -->2,080<!-- /STATUS --> / <!-- STATUS:conformance.runnable -->2,087<!-- /STATUS -->** runnable fixtures pass `spirv-val` — the official SPIR-V validator (verified 2026-05-31). <!-- STATUS:conformance.fail -->7<!-- /STATUS --> known feature-gap failures remain (64-bit int/float types, OpExtInst word-count on new-form texture builtins, `shader_ballot`, `ray_sphere`, `struct-material`); <!-- STATUS:conformance.skip -->8<!-- /STATUS --> skipped; <!-- STATUS:conformance.total -->2,095<!-- /STATUS --> total. These are pre-existing capability gaps, **not regressions**, and the suite exits non-zero while they remain.

### 3.2 DXC Validation

**47 / 51** pre-compiled SPIR-V→HLSL shaders compile with DXC (SM 6.0). The 4 failures are:
- 3 barycentric tests: `SV_Barycentrics` requires SM 6.1+; DXC also doesn't support two barycentric semantics in one shader
- 1 complex-expression: structured buffer exceeds DXC's 2,048-byte limit (actual: 16,384 bytes)

All 4 are DXC toolchain constraints, not glslpp bugs.

### 3.3 Cross-Compilation Validation

All 3 primary backends produce compilable output across the conformance corpus. Per-suite counts are now generated — see [docs/STATUS.md](STATUS.md).
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

- **No CI yet.** Conformance numbers come from local `zig build conformance` runs. Cross-platform (Linux / macOS) builds are unverified by automation; a GitHub Actions workflow is being added.
- **No published head-to-head benchmark against glslang's library form** (`libglslang.a` / `libspirv-cross.a` linked in-process). Current benchmarks compare glslpp library calls vs `glslangValidator` subprocess and so over-state the algorithmic win.
- **`spirv-val` is the conformance oracle, not glslang reference output.** Some test fixtures in `tests/spirv-cross/` are known to fail reference compilation with `glslangValidator` even though glslpp accepts them — see `docs/REFERENCE_FAILURE_ANALYSIS.md`.
- **Cross-compiler control flow assumes `OpSelectionMerge`.** Conditional branches and switches without merge information emit a `glslpp: unstructured branch — body elided` placeholder plus an `std.log.warn`. Well-formed SPIR-V coming from glslpp itself always has merge info; the limitation only matters for hand-authored or externally optimized SPIR-V.
- **C ABI bindings are not provided.** Consumers outside the Zig ecosystem need to write their own FFI layer.
- **Single-contributor project.** No formal release cadence yet; treat as alpha if you are not the wintty project.
