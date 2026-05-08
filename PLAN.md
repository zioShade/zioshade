# glslpp → wintty Drop-in: Master Task List

## Current State (baseline)
- **SPIR-V output**: 548/566 total pass (339/356 glslang-430 + 209/210 spirv-cross)
- **val_fail**: 17, **compile_fail**: 0, **crash**: 1
- **SPIR-V → HLSL**: stub returning `error.CodegenFailed`
- **SPIR-V → GLSL**: stub returning `error.CodegenFailed`
- **Preprocessor gaps**: no `#include`, no `##`/`#`, limited `#elif`/`defined()`
- **License**: none
- **wintty integration**: not started

## Performance comparison (to add)
We need a benchmark that measures:
1. **glslpp pipeline**: GLSL → SPIR-V → HLSL (pure Zig, single-thread)
2. **Current wintty pipeline**: GLSL → glslang (C++ via DLL) → spirv-cross (C++ via DLL) → HLSL
3. Measure: wall-clock time per shader, peak memory, binary size of host executable

---

## Phase 0: License & Project Setup (L1)
**Priority**: P0 (prerequisite for any public use)
**Estimated effort**: 30 min

- [ ] L1.1: Add `LICENSE-MIT` (SPDX standard text)
- [ ] L1.2: Add `LICENSE-APACHE` (SPDX standard text)
- [ ] L1.3: Add `LICENSE` file with dual-license statement
- [ ] L1.4: Add SPDX header to every `.zig` source in `src/`
- [ ] L1.5: Add `NOTICE` file
- [ ] L1.6: Add `THIRD_PARTY_NOTICES.md` for test shader licenses
- [ ] L1.7: Add `.github/FUNDING.yml`
- [ ] L1.8: Create/update README with sponsor badge and project description

---

## Phase 1: SPIR-V → HLSL Backend (B1) + Top-Level API (B2)
**Priority**: P0 (the single biggest blocker for wintty)
**Estimated effort**: 2-3 weeks

This is the core work. The approach: parse SPIR-V binary, walk the IR, emit HLSL.

### B1. SPIR-V → HLSL Implementation

#### Step 1: SPIR-V Binary Parser (SPIR-V IR reader)
- [ ] B1.1: Parse SPIR-V header (magic, version, bound, schema)
- [ ] B1.2: Decode all instructions into an in-memory IR
- [ ] B1.3: Build ID→definition map (what each ID is: type, constant, variable, function, etc.)
- [ ] B1.4: Walk entry points to find the target function
- [ ] B1.5: Extract decorations (binding, set, location, descriptor sets)
- [ ] B1.6: Extract types (OpTypeFloat, OpTypeInt, OpTypeVector, OpTypeMatrix, OpTypeArray, OpTypeStruct, OpTypePointer, OpTypeImage, OpTypeSampler, OpTypeSampledImage)
- [ ] B1.7: Extract constants (OpConstant, OpConstantComposite, OpConstantNull, etc.)

#### Step 2: HLSL Type Mapping
- [ ] B1.8: `float`/`vec2`/`vec3`/`vec4` → `float`/`float2`/`float3`/`float4`
- [ ] B1.9: `int`/`ivec2`/`ivec3`/`ivec4` → `int`/`int2`/`int3`/`int4`
- [ ] B1.10: `uint`/`uvec2`/`uvec3`/`uvec4` → `uint`/`uint2`/`uint3`/`uint4`
- [ ] B1.11: `bool`/`bvec2`/`bvec3`/`bvec4` → `bool`/`bool2`/`bool3`/`bool4`
- [ ] B1.12: `mat2`/`mat3`/`mat4` → `float2x2`/`float3x3`/`float4x4` (column-major)
- [ ] B1.13: Arrays → standard HLSL arrays
- [ ] B1.14: Structs → `struct` with HLSL types

#### Step 3: Resource Binding
- [ ] B1.15: Uniform blocks (UBO) → `cbuffer` with `register(bN)` (N from binding decoration)
- [ ] B1.16: `sampler2D` → `Texture2D tN : register(tN)` + `SamplerState sN : register(sN)`
- [ ] B1.17: `samplerCube` → `TextureCube` + `SamplerState`
- [ ] B1.18: SSBO → `RWByteAddressBuffer` or `StructuredBuffer`/`RWStructuredBuffer`
- [ ] B1.19: Binding remap: `binding=1` → `register(b0)` (wintty's DXC expects this)

#### Step 4: Entry Point & Semantics
- [ ] B1.20: Entry point named `main` with correct signature
- [ ] B1.21: `SV_Position` for `gl_FragCoord`
- [ ] B1.22: `SV_Target` for `gl_FragColor` / fragment output
- [ ] B1.23: `TEXCOORD0..N` for varyings
- [ ] B1.24: `SV_GroupThreadID`, `SV_GroupID`, `SV_DispatchThreadID` for compute

#### Step 5: Built-in Function Mapping
- [ ] B1.25: `texture(sampler, coord)` → `t.Sample(s, coord)`
- [ ] B1.26: `textureLod(sampler, coord, lod)` → `t.SampleLevel(s, coord, lod)`
- [ ] B1.27: `textureGrad(sampler, coord, ddx, ddy)` → `t.SampleGrad(s, coord, ddx, ddy)`
- [ ] B1.28: `dFdx(x)` → `ddx(x)`, `dFdy(x)` → `ddy(x)`, `fwidth(x)` → `fwidth(x)`
- [ ] B1.29: `mix` → `lerp`, `fract` → `frac`, `mod` → `fmod` (or manual)
- [ ] B1.30: `clamp`, `smoothstep`, `step` — same name in HLSL
- [ ] B1.31: `dot`, `cross`, `normalize`, `length`, `distance` — same name
- [ ] B1.32: `reflect`, `refract`, `faceforward` — same name
- [ ] B1.33: `transpose`, `determinant`, `inverse` — same name
- [ ] B1.34: `pow`, `exp`, `log`, `exp2`, `log2`, `sqrt`, `rsqrt` — same name
- [ ] B1.35: `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2` — same/`atan2`→`atan2`
- [ ] B1.36: `abs`, `sign`, `floor`, `ceil`, `min`, `max` — same name
- [ ] B1.37: `texelFetch` → `t.Load()`
- [ ] B1.38: Swizzle preserving (`.xyz`, `.xy` etc. — same syntax in HLSL)

#### Step 6: Control Flow
- [ ] B1.39: `if/else` → `if/else`
- [ ] B1.40: `for` → `for` (with loop variable scoping)
- [ ] B1.41: `while` → `while`
- [ ] B1.42: `break`/`continue`/`return`
- [ ] B1.43: `switch/case` (if used in wintty shaders)

#### Step 7: Operations
- [ ] B1.44: Arithmetic ops (+, -, *, /) — same syntax
- [ ] B1.45: Component-wise ops on vectors/matrices
- [ ] B1.46: Matrix multiply: `mat * vec` → `mul(mat, vec)` (order matters!)
- [ ] B1.47: Comparison ops — same syntax
- [ ] B1.48: Bitwise ops — same syntax
- [ ] B1.49: Ternary operator — same syntax
- [ ] B1.50: Vector constructor: `vec3(x, y, z)` → `float3(x, y, z)` and `float3(splat)`
- [ ] B1.51: Struct constructor → HLSL struct init

### B2. Top-Level API
- [ ] B2.1: Implement `compileShadertoyToHlsl(alloc, glsl, options)` — chains preprocess → parse → SPIR-V → HLSL
- [ ] B2.2: Implement `spirvToHLSL(alloc, spirv_words, options) ![]const u8`
- [ ] B2.3: Document free-on-error contract
- [ ] B2.4: Add wintty-compatible shadertoy prefix handling (binding=1→binding=0 remap)

### Testing
- [ ] B1.T1: Create `tests/wintty/` directory with the shadertoy prefix + test shaders
- [ ] B1.T2: Each wintty shader: glslpp HLSL compiles under DXC
- [ ] B1.T3: Render comparison: MSE < 1e-4 vs spirv-cross baseline

---

## Phase 2: Preprocessor Gaps (P1–P6)
**Priority**: P1 (Shadertoy shaders need these)
**Estimated effort**: 1 week

- [ ] P1.1: `#include "file"` relative includes
- [ ] P1.2: `#include <file>` search-path includes
- [ ] P1.3: Configurable include paths
- [ ] P1.4: Cycle detection
- [ ] P1.5: `__FILE__` / `#line` inside includes
- [ ] P2.1: Token-pasting `##`
- [ ] P2.2: Stringify `#`
- [ ] P3.1: `#elif` support
- [ ] P3.2: `defined(NAME)` / `defined NAME`
- [ ] P4.1: `#undef`
- [ ] P4.2: `#line N` / `#line N "file"`
- [ ] P4.3: `#pragma` passthrough, `#pragma once`
- [ ] P4.4: `#error msg`
- [ ] P4.5: `#warning msg`
- [ ] P5.1: `__VERSION__`, `GL_ES`, `GL_FRAGMENT_PRECISION_HIGH`
- [ ] P6.1: Fix body-collection bug (`;` tokens dropped)

---

## Phase 3: Build & Integration (I1–I5)
**Priority**: P2 (for wintty consumption)
**Estimated effort**: 3-5 days

- [ ] I1.1: `build.zig.zon` entry for consumption as Zig dependency
- [ ] I1.2: Standard `pub fn package(b)` or module export
- [ ] I1.3: No system dependencies at runtime
- [ ] I2.1: Lock public API types in `src/root.zig`
- [ ] I3.1: Verify no C++ runtime dependency (pure Zig)
- [ ] I4.1: Remove `threadlocal var last_compile_detail`
- [ ] I4.2: Move `last_error_line`/`last_error_column` into per-call result
- [ ] I4.3: Verify thread-safety with concurrent compiles
- [ ] I5.1: Single `alloc.free()` for all returned memory

---

## Phase 4: Semantic / Language Coverage (S1–S6)
**Priority**: P2 (ongoing improvement)
**Estimated effort**: ongoing

- [ ] S1.1: Resource limits struct
- [ ] S2.1: Vulkan/SPV rules mode
- [ ] S3.1: Document unsupported stages
- [ ] S4.1: Constructor splat/mix patterns
- [ ] S4.2: Implicit conversions
- [ ] S5.1–S5.5: Built-in function library
- [ ] S6.1: Shadertoy uniform shape preservation

---

## Phase 5: Diagnostics (D1–D3)
**Priority**: P3
**Estimated effort**: 3-5 days

- [ ] D1.1: Multi-error recovery
- [ ] D2.1: Full Diagnostic struct
- [ ] D3.1: Snippet formatter

---

## Phase 6: Conformance & Performance (C1–C6)
**Priority**: P2+ (gates the actual switch)

- [ ] C1.1: Root-cause failing wintty shader
- [ ] C2.1: Golden HLSL diff CI
- [ ] C3.1: DXC compile + render diff
- [ ] C4.1: spirv-val regression gate
- [ ] C5.1: Compile latency benchmark (< 50ms)
- [ ] C6.1: Allocation budget

### Performance comparison (NEW)
- [ ] PERF.1: Benchmark script measuring glslpp vs glslang+spirv-cross pipeline
  - Wall-clock time for each wintty shader
  - Peak RSS
  - Executable size (wintty with/without C++ DLLs)
- [ ] PERF.2: Document results in README or benchmark doc
- [ ] PERF.3: CI benchmark gate

---

## Phase 7: Nice-to-have (N1–N5)
**Priority**: P6 (post-switch)

- [ ] N1: SPIR-V → GLSL backend
- [ ] N2: SPIR-V → MSL backend
- [ ] N3: CLI binary (`glslpp` command)
- [ ] N4: WGSL output
- [ ] N5: Source maps

---

## Suggested Execution Order

### Sprint 1 (now): License + HLSL backend foundation
1. **L1** — License files ✅ DONE
2. **B1 steps 1-3** — SPIR-V parser + type mapping + resource binding ✅ DONE
3. **B1 steps 4-7** — Entry points + builtins + control flow + operations ✅ DONE (basic)
4. **B2** — Top-level API ✅ DONE
5. **PERF.1** — Performance comparison script (1 day)

**Current HLSL backend status (commit 2d9907d):**
- ✅ SPIR-V binary parsing (header, instructions, ID→def map)
- ✅ Type mapping (vec→floatN, mat→floatNxM, int/uint/bool/float)
- ✅ Resource binding (UBO→cbuffer with binding remap binding=1→b0)
- ✅ Texture/sampler splitting (combined image-sampler → Texture2D + SamplerState)
- ✅ Correct texture sampling: `tex.Sample(sampler, coord)`
- ✅ Constant inlining (scalars as literal values, vectors as constructors)
- ✅ User function emission (mainImage, curve, etc.)
- ✅ FunctionCall with argument passing
- ✅ GLSLstd450 → HLSL builtins (40+ functions mapped)
- ✅ Arithmetic/comparison/bitwise/conversion/composite ops
- ✅ Public API: spirvToHLSL(), compileShadertoyToHlsl()
- ⚠️ Vector component writes use _m0 instead of .x (AccessChain issue)
- ⚠️ Control flow: if/else skeleton present, needs full block reconstruction
- ⚠️ Loops: not yet reconstructed
- ❌ DXC compilation: not yet tested (needs fixes above first)

**Test result:** CRT shadertoy shader → 212 lines of HLSL, 0 unhandled ops

### Sprint 2: Preprocessor + wintty test corpus
1. **P1–P6** — Preprocessor gaps (5 days)
2. **B1.T1–T3** — wintty test corpus + DXC validation (2 days)
3. **C1** — Fix any failing wintty shaders (2 days)

### Sprint 3: Build integration + cleanup
1. **I1–I5** — Build/integration (3-5 days)
2. **D1–D3** — Diagnostics (3-5 days)
3. **C2–C6** — Conformance gates + performance (3-5 days)

### Sprint 4: Wire into wintty
1. Add glslpp as dependency in wintty
2. Add `glslpp` build flag in wintty
3. Run side-by-side comparison
4. Flip default
5. Delete `pkg/glslang/`, `pkg/spirv-cross/`, `shader_wrapper.cpp`, `build_msvc.bat`, 8MB-stack workaround
