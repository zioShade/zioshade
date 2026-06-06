# Changelog

All notable changes to glslpp are documented here. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [SemVer](https://semver.org/) on the public API exported from `src/root.zig`.

## [Unreleased]

### Fixed (silent-wrong elimination, all oracle-gated)
- **WGSL coverage deepening, Pass 1 (G5, #170):** three classes of WGSL backend defects, all naga-gated:
  - **`findMSB(uint)` was a needless honest-error:** GLSL `findMSB` on an unsigned operand emits GLSL.std.450 **FindUMsb (75)**, which was missing from the shared name table → `error.UnsupportedExtInst` for an op WGSL fully supports. FindUMsb/FindSMsb/FindILsb now map directly to `firstLeadingBit`/`firstTrailingBit` in the single-source-of-truth table (retiring a dead main-path-only remap). GLSL findMSB/findLSB always return *signed* int even for an unsigned operand, while WGSL's bit-scan builtins return the argument's type, so the result is wrapped in an explicit `rt(…)` conversion (identity cast when types already match) in both the main and loop/switch-replay ExtInst paths. Also added the NaN-variants **NMin (79) → `min`, NMax (80) → `max`, NClamp (81) → `clamp`** (spirv-cross mappings, naga-validated).
  - **Projective texture sampling is now lowered dimension-aware (non-Dref), Dref honest-errored:** `textureProj*` (ImageSampleProj{Implicit,Explicit,DrefImplicit,DrefExplicit}Lod) previously lowered to a hard-coded `textureSample(t, s, coord.xy / coord.w)` — correct *only* for the 2D/vec4 case, but wrong for vec3 coords (the divisor must be the coordinate's LAST component, `.z`, not `.w`) and for 3D/cube/Dref forms. Pass 1 over-corrected it to a blanket honest-error, which regressed the working 2D case. The non-Dref forms (ImageSampleProjImplicitLod/ExplicitLod) now lower **dimension-aware**: the coordinate is divided by its actual last component (read from the operand vector width) and the leading components match the sampler dimensionality (`.x` 1D / `.xy` 2D / `.xyz` 3D), producing a naga-validated `textureSample`/`textureSampleLevel`. The projective **depth-compare** forms (ImageSampleProjDref{Implicit,Explicit}Lod) and **cube/arrayed** projective forms have no faithful WGSL mapping and stay an honest `error.UnsupportedOp` ("WGSL has no projective depth-compare sampling" / "… for this sampler kind") rather than silently dropping the compare. (The ExplicitLod path mirrors the non-proj arm but is not yet reachable through glslpp's GLSL frontend, which rejects `textureProjLod` itself — see deferred note.)
  - **Fragment-shader interlock barriers silently dropped:** `OpBeginInvocationInterlockEXT`/`OpEndInvocationInterlockEXT` were unhandled (dropped). They now honest-error with `error.UnsupportedOp` as defense-in-depth (the interlock *execution mode* was already caught).
  - **The main-path `else` placeholder was silent-wrong:** the fallback emitted `// unhandled op N` + an uninitialised `var <name>: T;` (a garbage value that naga nonetheless accepts as valid syntax). It now **fails loud** with `error.UnsupportedOp` ("WGSL: unsupported op …"), mirroring the loop/switch-replay `else` which already did. Verified safe: a grep for `"unhandled op"` over the full conformance corpus output is empty, so nothing representable relied on the placeholder.
- **Module-scope `const` array globals read uninitialised memory (all backends):** a `const T arr[N] = T[](…)` global indexed by a *runtime* value lowered to a Private `OpVariable` with no initializer and no stores — its values appeared nowhere in the SPIR-V, so every backend read garbage. The frontend now folds the initializer to an `OpConstantComposite` and emits it as the variable's initializer (spirv-val clean). **GLSL** (`const T v[N] = {…}`, glslang-validated), **HLSL** (`static const`, dxc-validated), and **WGSL** (`const v: array<T,N> = array<T,N>(…)`, naga-validated) materialise the values; **MSL** indexes the read-only const array via a program-scope `constant T name[N] = {…}` (valid Metal, simpler than spirv-cross's always-`spvUnsafeArray`).
- **MSL whole-array VALUE ops emitted illegal Metal (#168):** a whole-array `OpLoad`/`OpStore` — e.g. a value copy `float local[N] = LUT;` — was typed by `mslType()`, which drops the `[N]` and returns only the element type, producing `float v14 = v3;` (a scalar-from-array load) and `v13 = v14;` (a C-array whole-copy — illegal, Metal C-arrays aren't assignable). The backend now uses the `spvUnsafeArray<T,N>` template as the array **value** type at value-context sites, emitted once and gated on need — mirroring `spirv-cross --msl`. Each fix is oracle-gated against `spirv-cross --msl` for structural equivalence. **Now supported (legal `spvUnsafeArray<T,N>` everywhere):**
  - whole-array `OpLoad` value copy from a const global (`float local[N] = LUT;`) — the headline case;
  - **local→local** whole-array copy — BOTH the source AND destination function locals are spelled `spvUnsafeArray` (the source-local was previously left a C-array → illegal copy);
  - **`OpSelect`/ternary** on whole arrays (`float la[N] = cond ? A : B;`) — the Select result and its dest are `spvUnsafeArray` (was a scalar-from-array Select);
  - **`OpCompositeConstruct`** of an array (`float arr[N] = float[](a,b,c);`) — emits `spvUnsafeArray<T,N>({ a, b, c })` (was a bogus `float(a,b,c)` scalar ctor + C-array copy);
  - **struct-element** const-array value copy (`const S LUT[N]; S local[N]=LUT;`) — `struct S` is now declared **before** the `constant spvUnsafeArray<S,N>` that references it (was use-before-declaration).
  - The read-only index-only path keeps the plain `constant T[N]` spelling (intentional, valid divergence). The `.Load` template spelling is narrowed to loads whose source is itself an `spvUnsafeArray` (a value-copied const or value-copied local); a whole-array load from any other source now **fails loud** (`UnsupportedWholeArrayValueLoad`) instead of emitting a template/​C-array mismatch.
  - **Honest-errored (no silent-wrong), deferred to a frontend fix — see #173:** a **spec-constant-sized** array used as a whole-array value (`mslValueType` cannot read a literal length → `UnresolvableArrayLength`, was silently sized `<T,1>`); a **matrix-element** const-array global (`const mat4 M[N]`) that the frontend does not fold to an `OpConstantComposite` → `UndeclaredPrivateArrayGlobal` (was a reference to an undefined `M` identifier). Nested multi-dimensional const-array globals copied whole likewise still depend on a separate, pre-existing frontend folding bug; out of scope here.
- **Spec-constant array indexed by a runtime expression produced dangling SPIR-V:** a constant evaluated at top level (spec-constant default / global `const`) was cached but its instruction discarded, so a later function referenced an unemitted constant (`OpISub %<dangling> %a`) → invalid SPIR-V with exit 0. The top-level constant cache is now cleared before function analysis. (`spec-constant-work-group-size.vk.comp` now passes; strict-gate restored to green.)
- **GLSL integer fragment inputs missing `flat`:** glslang requires `flat` on integer/double fragment inputs; the backend dropped the `Flat` decoration → glslang-rejected output. Now emitted faithfully (fragment inputs and flat vertex outputs).
- **GLSL multidimensional array locals dropped a dimension** (`vec4 v[2];` for a `vec4[2][2]` value) → glslang type-mismatch on assignment. The local-var array suffix now walks all nested dimensions.
- **Float-vector constructor sign flip:** `vec2(2147483648, 0)` folded the bare (signed) integer literal with the wrong sign (`+2.147e9`); glslang wraps 2³¹ to `-2147483648` → `-2.147e9`. Now matches glslang; `u`-suffixed literals stay unsigned.

### Added
- **Deeper SPIR-V reflection metadata (G1 Batch A, #171):** `reflectSPIRV` now surfaces the layout decorations glslpp already bakes into its output, **read back from the SPIR-V decoration table — never recomputed** (recomputing std140/std430 would re-introduce divergence). New `reflection.Member` fields: `array_stride` (from `ArrayStride`/Decoration 6, keyed by the array TYPE id), `matrix_stride` (`MatrixStride`/7), `is_row_major` (`RowMajor`/4 vs `ColMajor`/5), `is_runtime_array` (true for `OpTypeRuntimeArray`, detected by op 29 — previously unhandled — not by a zero length), and `array_dim` (fixed element count, 0 for runtime). New `reflection.Resource` fields: `block_size` (derived as `last_member.offset + last_member.size`, so a runtime-only/`writeonly` block is legitimately 0), `readonly` (`NonWritable`/24 on the variable) and `writeonly` (`NonReadable`/25). All scalar/bool, so `ShaderResources.deinit` is unchanged. Two oracle-gated tests (`spirv-cross --reflect`) cover a matrix+array UBO and a runtime-tail-array readonly/writeonly SSBO pair. The CLI `reflect` text dumper now prints these per-member/per-block. **Deferred (follow-up #177):** nested-struct member recursion, JSON serialization, per-member Coherent/Volatile/Restrict.
- **Selectable GLSL output version 330–460 (G4, #169):** the GLSL backend's `version` field is now honoured across the whole desktop range `{330, 400, 410, 420, 430, 440, 450, 460}` (default unchanged at 430), with three pieces of real work behind it:
  - **Honest-error (Tier 1):** an unsupported `version` now fails loud with `error.UnsupportedGlslVersion`, and `es = true` (ESSL, out of scope for #169) fails loud with `error.EsslUnsupported` instead of being silently accepted-and-ignored. Both are surfaced by the CLI.
  - **`GL_ARB_shading_language_420pack` guard (Tier 2):** at versions `< 420` the backend emits the `#ifdef GL_ARB_shading_language_420pack / #extension … : require / #endif` guard (verbatim, matching spirv-cross) so `layout(binding=)` validates — glslangValidator now accepts the 330/410 output.
  - **`layout(location=)` gating on varyings (Tier 3):** at version 330 the location qualifier is dropped on fragment-stage *inputs* and vertex-stage *outputs* (where glslang rejects it) and kept everywhere else (vertex inputs, fragment outputs, all varyings at ≥ 410) — matching glslang's rules and spirv-cross's output.
  - Verified by new glslangValidator-acceptance and spirv-cross structural-compare tests in `tests/cross_compare_tests.zig` (330/410/450/460). Default 430 output is byte-identical to before.
- **Single-source-of-truth status numbers (`just status`):** `tools/gen_status.sh` regenerates `docs/STATUS.md` from a real `zig build conformance` run (spirv-val gate), so the conformance counts cited in docs are generated, never hand-typed — they cannot silently go stale. `docs/IMPLEMENTATION_STATUS.md` now links to `STATUS.md` instead of carrying a hand-typed count.
- **Lib-vs-lib benchmark (`just lib-bench`):** links SPIRV-Cross in-process (C API, Vulkan SDK static libs) and times glslpp vs SPIRV-Cross on the same SPIR-V → GLSL/HLSL/MSL — an honest comparison (no subprocess). glslpp is ~1.4–1.6× faster on the median cell (parity on a trivial GLSL shader, up to ~2.6× on math/control-flow-heavy MSL; machine-relative).

## [0.1.0] - 2026-06-02

First tagged release. **Alpha / pre-1.0 — the public API (`src/root.zig`) is not
yet stable and MAY change in any `0.x` bump** (per SemVer §4). Current trust
baseline: `spirv-val` conformance **2074 PASS / 0 FAIL / 8 SKIP / 15 XFAIL**
(`just test-conformance`, exits 0); analyzer fail-loud keystone complete (zero
false-positives, no silent-wrong); every backend oracle-gated (spirv-val /
glslangValidator / dxc / spirv-cross / naga); structured-GLSL fuzzer clean over
**1,000,000 iterations** (`just fuzz-million`). Not a full glslang / SPIRV-Cross
drop-in — see `docs/IMPLEMENTATION_STATUS.md` for the honest gap analysis.

### Changed
- README rewritten with honest scoping; explicit "this is not a full glslang/SPIRV-Cross drop-in" framing.
- Conformance numbers updated: 1,894 / 1,894 `spirv-val` fixtures (was 1,811); 47 / 51 DXC fixtures (was 51 / 51); WGSL stress 264 / 264.
- Code-gen safety: replaced three `@panic` call-sites in `src/codegen.zig` with `std.log.err` + invalid-id fallback so malformed IR no longer crashes the host process.
- Cross-compiler control flow: unstructured CFG (an `OpBranchConditional`/`OpSwitch` with no `OpSelectionMerge`/`OpLoopMerge`) now **fails loud** with `error.UnstructuredControlFlow` on every backend (GLSL/HLSL/MSL/WGSL) instead of a lossy convergence-guessing reconstruction that could silently drop `switch` default cases. glslpp's own SPIR-V always carries merge info; this only affects externally-optimized / hand-authored SPIR-V. Full CFG structurization is future work.
- Internal: `std.debug.print` in `compact_ids_passes.zig` identity-store elimination demoted to `std.log.debug`.
- `src/gap_tests.zig` is now wired into `zig build test` via `src/root.zig`.

### Fixed (silent-wrong elimination, all oracle-gated)
- **MSL built-in I/O:** `gl_VertexIndex`/`gl_InstanceIndex` (`[[vertex_id]]`/`[[instance_id]]`), `gl_FrontFacing` (`[[front_facing]]`), `gl_PointSize` (`[[point_size]]`), and the compute IDs (`[[thread_position_in_threadgroup]]` etc.) were emitted as bare undeclared identifiers (uncompilable MSL); now threaded as entry-point attributes (vs `spirv-cross --msl`).
- **HLSL built-in I/O:** compute IDs → `SV_DispatchThreadID`/`SV_GroupThreadID`/`SV_GroupID`/`SV_GroupIndex`; `SV_VertexID`/`SV_InstanceID` forced to `uint` (dxc-validated).
- **WGSL:** `vertex_index`/`instance_index` as `u32` (+ `i32` conversion); `textureGather` component as the first argument; constant vector ctor `vec2<u32>(...)` (was GLSL `uintN`); shared-block var renamed to avoid struct-name collision; `OpSelectionMerge`/`OpLoopMerge`/`CompositeExtract`/`Select` handled (or honest-errored) in the switch/loop replay path; unmapped input built-ins (e.g. `gl_PointCoord`) honest-error instead of fabricating `@builtin(position)`; QCOM image ops honest-error. naga-gated; large-corpus REJECTs cut from 152 to a small deep-debug tail.
- **GLSL backend:** vertex attributes/varyings and fragment input varyings are now declared (`layout(location=N) in/out`); previously only the single fragment color output was declared (glslang-validated).

### Added
- **Descriptor remap (G6):** `HlslCompileOptions.resource_bindings` / `MslCompileOptions.resource_bindings` map a SPIR-V `(set, binding)` to an explicit HLSL register / MSL slot (class inferred from type); CLI `--bind set:binding:reg` (repeatable). dxc/spirv-cross-gated.
- **Fuzzing milestone:** the structured-GLSL fuzzer is clean over **1,000,000 iterations** (0 fail / 0 crash, seed 1). Reproduce with `just fuzz-million` (or `just fuzz <count>`).
- `docs/IMPLEMENTATION_STATUS.md` — renamed and reframed gap analysis with an explicit "Other gaps" section flagging un-published comparisons against `libglslang.a`.
- `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`.
- `examples/glsl_to_hlsl.zig` and `examples/reflect_uniforms.zig` runnable demos.
- `.github/workflows/ci.yml` running `zig build test` and `zig build conformance` on Linux / macOS / Windows.

### Removed
- Dead `CrossCompileOptions` struct (its `flatten_ubos` field was a phantom no-op; UBO flatten is not yet implemented and is no longer advertised).
- Repository hygiene: stripped binaries (`*.exe`, `*.pdb`), SPIR-V scratch dumps (`dump_*.spv`), internal planning artifacts (`HANDOFF.md`, `PLAN.md`, `autoresearch.*`, `docs/plans/`, `docs/superpowers/`), and scratch debugging sources from the repo and all branch history.

### What works (initial public release)
First publicly-tagged release. Extracted from the wintty project after the C++ glslang + SPIRV-Cross migration was completed.
- GLSL → SPIR-V (`compileToSPIRV`) for GLSL 430-class fragment / vertex / compute shaders; SPIR-V 1.0 through 1.6 output.
- SPIR-V → HLSL (SM 6.0), GLSL (430), MSL (2.0+), WGSL (shallow, frag/vert/comp).
- Partial reflection (`reflectSPIRV`) — uniform / sampler enumeration.
- SPIR-V optimizer passes (DCE, constant fold, CSE, identity-store elim, etc.).
- Kernel fusion and SPIR-V module linking.
- 1,894 `spirv-val` conformance fixtures passing.

### Known gaps (at initial public release)
See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md). Headline items: no specialization constants, single GLSL output version, shallow WGSL backend, control flow requires `OpSelectionMerge`, no CI yet.
