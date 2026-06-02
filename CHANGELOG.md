# Changelog

All notable changes to glslpp are documented here. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [SemVer](https://semver.org/) on the public API exported from `src/root.zig`.

## [Unreleased]

### Added
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
- `examples/glsl-to-hlsl.zig` and `examples/reflect-uniforms.zig` runnable demos.
- `.github/workflows/ci.yml` running `zig build test` and `zig build conformance` on Linux / macOS / Windows.

### Removed
- Dead `CrossCompileOptions` struct (its `flatten_ubos` field was a phantom no-op; UBO flatten is not yet implemented and is no longer advertised).
- Repository hygiene: stripped binaries (`*.exe`, `*.pdb`), SPIR-V scratch dumps (`dump_*.spv`), internal planning artifacts (`HANDOFF.md`, `PLAN.md`, `autoresearch.*`, `docs/plans/`, `docs/superpowers/`), and scratch debugging sources from the repo and all branch history.

## [0.1.0] — initial public release

First publicly-tagged release. Extracted from the wintty project after the C++ glslang + SPIRV-Cross migration was completed.

### What works
- GLSL → SPIR-V (`compileToSPIRV`) for GLSL 430-class fragment / vertex / compute shaders; SPIR-V 1.0 through 1.6 output.
- SPIR-V → HLSL (SM 6.0), GLSL (430), MSL (2.0+), WGSL (shallow, frag/vert/comp).
- Partial reflection (`reflectSPIRV`) — uniform / sampler enumeration.
- SPIR-V optimizer passes (DCE, constant fold, CSE, identity-store elim, etc.).
- Kernel fusion and SPIR-V module linking.
- 1,894 `spirv-val` conformance fixtures passing.

### Known gaps
See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md). Headline items: no specialization constants, single GLSL output version, shallow WGSL backend, control flow requires `OpSelectionMerge`, no CI yet.
