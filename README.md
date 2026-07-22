# zioshade

**A pure-Zig shading-language compiler: GLSL to SPIR-V to HLSL / MSL / GLSL / WGSL, in one module, no C++ runtime.**[^name]

[![CI](https://github.com/zioshade/zioshade/actions/workflows/ci.yml/badge.svg)](https://github.com/zioshade/zioshade/actions/workflows/ci.yml)
[![Conformance](https://img.shields.io/badge/strict--gate-PASS%202102-brightgreen)](docs/STATUS.md)
[![Fuzz](https://img.shields.io/badge/fuzz-1M%20clean-brightgreen)](#correctness-how-a-single-maintainer-compiler-earns-trust)
[![Zig](https://img.shields.io/badge/Zig-0.15.2-f7a41d)](https://ziglang.org/download/0.15.2/)
[![License](https://img.shields.io/badge/license-MIT%20%2F%20Apache--2.0-blue)](#license)
[![Sponsor](https://img.shields.io/github/sponsors/deblasis)](https://github.com/sponsors/deblasis)

> **Requires Zig 0.15.2 or newer** (see [Supported Zig versions](#supported-zig-versions)). The library, CLI, C ABI, and full test suite build and pass on both 0.15.2 and 0.16.

## Why this exists

[wintty](https://github.com/deblasis/wintty), a GPU-accelerated terminal emulator, needs to compile shaders at startup before it can draw a frame. Doing that the usual way meant shipping glslang plus SPIRV-Cross, a stack of C++ dependencies invoked as subprocesses, just to turn GLSL into HLSL / MSL / WGSL. zioshade replaces that whole surface with a single Zig module that links directly into the host, with no C++ runtime, no system dependencies, and no subprocess spawns.

The cost of that toolchain is not really its byte size. Measured on a typical Homebrew install, the glslang and SPIRV-Cross libraries a host links come to roughly 9 MB (about 19 MB for the full toolchain with headers and CLIs) — comparable to zioshade's own binary, so size alone is a wash. What zioshade actually removes is the C++ build and dependency surface: two CMake projects, their transitive headers, and either an in-process C++ link or a per-shader subprocess spawn, all replaced by a single Zig module that compiles into the host. That simplification, not a raw megabyte count, is the point; the performance win over the subprocess path (below) is the measurable payoff.

> **Scope:** zioshade is **not** a full Khronos drop-in. It is a focused replacement for the shader-compilation surface wintty needs (GLSL 330-460 class shaders to SPIR-V to a backend), validated on the projects' own reference suites and a 2,100+ fixture strict gate. If you need full GLSL ES, complete descriptor-set reflection, or SPIRV-Cross-grade WGSL output, use upstream. See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) for the full gap analysis.

## How it compares

|  | **zioshade** | glslang + SPIRV-Cross | naga | Tint |
|---|---|---|---|---|
| Language / toolchain | Zig, single module | C++ | Rust | C++ (Dawn) |
| In-process from Zig / C | Yes, Zig module + C ABI header/lib | Link the C++ libs | Rust crate, no C ABI | Link the C++ (Dawn) libs |
| GLSL in | Yes (330-460) | Yes (glslang frontend) | Yes (GLSL frontend, actively maintained) | No (WGSL / SPIR-V in) |
| HLSL out | Yes | Yes | Yes | Yes |
| MSL out | Yes | Yes | Yes | Yes |
| WGSL out | Yes (shallow, see below) | No (SPIRV-Cross has no WGSL backend) | Yes | Yes |
| License | MIT / Apache-2.0 | Apache-2.0 / BSD | MIT / Apache-2.0 | BSD-3-Clause |
| Coverage | **wintty scope**, validated on the 2,100+ fixture strict gate; **not** full Khronos | Full Khronos reference coverage | Broad, production (Firefox / wgpu) | Broad, production (Chrome / Dawn) |

The honest line is the last row. glslang + SPIRV-Cross, naga, and Tint are broad, mature, multi-contributor projects. zioshade is deliberately narrow: it does the transforms wintty needs, extremely fast, in-process from Zig, and it is validated against those exact fixtures rather than the full specification surface. It wins on embed-ability and startup cost, not on breadth.

## Quick start

zioshade requires **Zig 0.15.2** (the system Zig on most machines is newer and will not build it):

```bash
mise trust && mise install      # honors the pinned .mise.toml; then prefix builds with `mise exec --`
# or install Zig 0.15.2 directly: https://ziglang.org/download/0.15.2/
```

```bash
zig build cli

# GLSL to SPIR-V (examples/shader.frag ships with the repo)
zig-out/bin/zioshade compile examples/shader.frag -o shader.spv

# Cross-compile to a backend
zig-out/bin/zioshade hlsl examples/shader.frag -o shader.hlsl
zig-out/bin/zioshade msl  examples/shader.frag -o shader.msl
zig-out/bin/zioshade wgsl examples/shader.frag -o shader.wgsl

# With preprocessor defines and include paths
zig-out/bin/zioshade wgsl examples/shader.frag -DDEBUG=1 -DQUALITY=3 -I src/shaders/

# Reflect a SPIR-V binary
zig-out/bin/zioshade reflect shader.spv
```

Using it as a Zig dependency, the C ABI (`include/zioshade.h`, built with `zig build c-lib`), the full CLI surface, and the complete API table all live in the sections below and in [`examples/`](examples/).

## Correctness: how a single-maintainer compiler earns trust

A compiler written by one person is only worth using if you can check its work without trusting the author. zioshade's answer is to validate every output with the competitors' own tools, so the claim is not "trust me" but "the reference implementations agree":

- **Khronos `spirv-val` on 2000+ fixtures.** Every fixture's SPIR-V is validated by the Khronos validator. `zig build strict-gate` reports **PASS 2102, XFAIL 13 (documented rejections), 0 FP-regression**; [docs/STATUS.md](docs/STATUS.md) is the single source of truth for these counts.
- **DXC on the HLSL output.** Emitted HLSL is fed to Microsoft's `dxc` and compiled to DXIL; 47/51 fragment fixtures pass at SM 6.0 (the rest need SM 6.1+ dialects), see [BENCHMARKS.md](BENCHMARKS.md).
- **naga-gated WGSL.** WGSL output is piped through `naga` (the wgpu / Firefox implementation) as an external acceptance check; the WGSL fix history is a long list of "naga rejected this, so we fixed it or turned it into a loud error."
- **`just prove` — a reproducible differential proof across all three shader stages.** zioshade's output and an independent glslang → SPIRV-Cross reference are *executed on a real GPU* and compared: fragment shaders by rendered pixels, vertex shaders by captured `gl_Position`, compute shaders by output buffers. One command prints an honest report (`verified / benign / divergences / skipped-with-reason`) and exits nonzero on any real divergence, so it doubles as a regression gate. A representative run is **164 shaders verified, 0 divergences** — spanning both SPIRV-Cross's own test suite and a hand-written real-world corpus (mandelbrot, julia, plasma, phong, hash-noise, terrain). This is the strongest check: compile-clean is not render-correct, and a differential render/execution oracle is the only thing that catches a silently-wrong output. See [docs/DIFFERENTIAL_PROOF.md](docs/DIFFERENTIAL_PROOF.md).
- **1,000,000-iteration fuzz.** The structured-GLSL fuzzer is clean over a million iterations (`just fuzz-million`; ad-hoc `zig build fuzz -- --count N`).

### The named principle: honest error, never miscompile

The contract underneath all of that is one rule: **when zioshade cannot faithfully translate a construct, it returns a loud error rather than emitting plausible-but-wrong output.** A rejected shader is a bug report; a silently miscompiled shader is a trap. Every entry in the WGSL history above exists because a "silent-wrong" was found and converted into either a correct lowering or an explicit `error.UnsupportedOp`. The 13 XFAIL fixtures are documented, curated rejections (see `KNOWN_UNSUPPORTED` in `tests/runner.zig`), not silent failures.

## Performance

**Honest headline (library vs library, in-process).** Linking SPIRV-Cross in-process through its C API and timing both sides on identical SPIR-V (SPIR-V to GLSL / HLSL / MSL), zioshade is roughly **1.4-1.6x faster on the median cell**, from parity on a trivial GLSL shader up to ~2.6x on math / control-flow-heavy MSL. No process-spawn advantage, both are plain in-process parse-and-emit. Numbers are machine-relative; reproduce with `just lib-bench`. Methodology and the front-end caveat (the zioshade-vs-`libglslang.a` half is not wired yet) are in [BENCHMARKS.md](BENCHMARKS.md).

**Workflow benchmark (vs subprocess CLIs).** Most build pipelines do not link the C++ libraries; they spawn `glslangValidator` and `spirv-cross` per shader. Against that real-world integration, in-process zioshade is **150-265x faster** and produces **5-47% smaller HLSL**:

| Shader | zioshade avg | reference avg (subprocess) | **speedup** |
|---|---:|---:|---:|
| `trivial_frag` | 732 µs | 194 ms | **265x** |
| `typical_frag` (UBO + math) | 986 µs | 181 ms | **184x** |
| `raymarch` (loop + SDF) | 1.17 ms | 181 ms | **154x** |
| `simple_compute` (SSBO) | 1.04 ms | 190 ms | **183x** |

This is a **workflow win, not an algorithm win**: most of the gap is process-spawn overhead (~150 ms per `CreateProcess` on Windows), which is exactly what wintty's startup could not afford. For wintty's 10-shader startup that is ~1.8 s of subprocess spawning turned into ~10 ms. Windows 11 / Zig 0.15.2 / Vulkan SDK 1.4.341.1, 50 iterations, `ReleaseFast`; reproduce with `zig build bench-compare`. Full methodology in [BENCHMARKS.md](BENCHMARKS.md).

## Features

- **GLSL to SPIR-V**: GLSL 330-460 to SPIR-V 1.0-1.6
- **SPIR-V to HLSL / GLSL / MSL / WGSL**: cross-compile to HLSL SM 6.0, GLSL 430, MSL 2.0+, and WGSL (shallow coverage, see status doc)
- **Reflection**: enumerate uniform buffers, inputs/outputs, samplers from SPIR-V (partial, no full descriptor metadata)
- **Kernel fusion / SPIR-V linking**: merge multiple compute shaders or SPIR-V modules
- **Shadertoy support**: one-shot API for Shadertoy-style fragment shaders
- **Zero C++ dependency**: pure Zig, builds with `zig build`
- **In-process, threadlocal state only**: safe to call from multiple threads; no process-wide init/finalize
- **C ABI**: a C header (`include/zioshade.h`) and shared/static libraries for non-Zig consumers (`zig build c-lib`)

## API surface

```zig
const zioshade = @import("zioshade");

// GLSL to SPIR-V
const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment, .version = 430 });
defer alloc.free(spirv);

// SPIR-V to any backend
const hlsl = try zioshade.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
const wgsl = try zioshade.spirvToWGSL(alloc, spirv, .{});

// One-shot: GLSL to backend
const hlsl_one = try zioshade.compileGlslToHlsl(alloc, source, .fragment);
const msl_one  = try zioshade.compileGlslToMsl(alloc, source, .fragment);
const wgsl_one = try zioshade.compileGlslToWgsl(alloc, source, .fragment);

// Reflection (deinit takes *ShaderResources, so bind with `var`)
var resources = try zioshade.reflectSPIRV(alloc, spirv);
defer resources.deinit(alloc);
```

| Category | Functions |
|---|---|
| Compilation | `compileToSPIRV`, `compileToSPIRVNoOpt`, `compileToSPIRVWithDiagnostics`, `compileToSPIRVWithFusion` |
| Cross-compilation | `spirvToHLSL`, `spirvToGLSL`, `spirvToMSL`, `spirvToWGSL` |
| One-shot (GLSL to backend) | `compileGlslToHlsl`, `compileGlslToMsl`, `compileGlslToGlsl`, `compileGlslToWgsl`, `compileShadertoyToHlsl` |
| Utilities | `reflectSPIRV`, `reflectGLSL`, `validateSPIRV`, `linkSPIRVModules`, `compileMultiKernel` |

Add zioshade to `build.zig.zon` with `zig fetch`, then `exe.root_module.addImport("zioshade", zioshade_dep.module("zioshade"))`. See [`examples/`](examples/) for runnable end-to-end programs, including error handling with diagnostics.

## Supported shader stages

| Stage | SPIR-V | HLSL | GLSL | MSL | WGSL |
|---|---|---|---|---|---|
| Vertex | Yes | Yes | Yes | Yes | Yes |
| Fragment | Yes | Yes | Yes | Yes | Yes |
| Compute | Yes | Yes | Yes | Yes | Yes |
| Geometry | Yes | Yes | Yes | Yes | - |
| Tessellation (TCS / TES) | Yes | Yes | Yes | Yes | - |
| Mesh / Task | Basic | - | - | - | - |
| Ray tracing | Basic | - | - | - | - |

## Known limitations

- **GLSL output is 430 only.** Other versions are not generated.
- **WGSL backend is shallow** versus SPIRV-Cross: common opcodes only. Deepening it is tracked in [#170](https://github.com/zioshade/zioshade/issues/170).
- **Cross-compiler control flow:** structured SPIR-V works on every backend; unstructured-but-reducible `if`/`switch` (missing `OpSelectionMerge`) is structurized transparently by a pre-pass. Unstructured loops (missing `OpLoopMerge`) and irreducible CFGs **fail loud** with `error.UnstructuredControlFlow` rather than miscompile. zioshade's own SPIR-V is always structured; this only affects externally-optimized or hand-authored input.
- **Single contributor.** Treat as alpha if you are not the wintty project.

See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) for the complete feature-by-feature comparison against glslang / SPIRV-Cross.

## Roadmap

- **WGSL opcode depth** toward SPIRV-Cross parity: [#170](https://github.com/zioshade/zioshade/issues/170).
- **Zig 0.16 dev tools**: the library, CLI, C ABI, and test suite already build and pass on 0.16; the standalone dev tools under `tools/` are the last holdout ([#424](https://github.com/zioshade/zioshade/issues/424)).
- **GLSL backend fixes** for legacy / array-of-structs / loose-uniform edge cases: [#417](https://github.com/zioshade/zioshade/issues/417), [#418](https://github.com/zioshade/zioshade/issues/418), [#419](https://github.com/zioshade/zioshade/issues/419), [#420](https://github.com/zioshade/zioshade/issues/420).
- **Front-end lib-vs-lib benchmark** against `libglslang.a` (the GLSL to SPIR-V half is not yet wired).

## FAQ

**Why not just use naga?** naga is excellent and its GLSL frontend is actively maintained, but it is a Rust crate with no C ABI. Embedding it in a Zig codebase like wintty means pulling a Rust toolchain into the build and writing FFI glue. zioshade is one Zig module that links straight into the host with no extra toolchain and no subprocess, which was the entire point. If you are already in a Rust project, naga is very likely the better choice.

**Was this AI-built?** It was built with heavy use of AI assistance, and the workflow is the reason to take the output seriously rather than a reason to distrust it. Every change runs through a verification loop: an adversarial reviewer, `spirv-val` / DXC / naga acceptance gates, pixel-compare renders, and the million-iteration fuzzer. The "honest error, never miscompile" principle exists precisely so that anything the loop cannot prove correct fails loudly instead of shipping. The tools do the writing; the reference implementations do the judging.

**Why GLSL in 2026?** Because the shaders people actually have, in engines, terminals, Shadertoy, and existing pipelines, are still overwhelmingly GLSL, and they need to reach HLSL / MSL / WGSL to run on DX12, Metal, and WebGPU. GLSL to everywhere is the transform wintty needed and the one this compiler is built around.

**How do I pronounce it?** ZEE-oh-shade.

**Version policy?** SemVer on the public API exported from `src/root.zig`, currently `0.3.0`. Pre-1.0, so minor bumps may break API. Builds on Zig 0.15.2 through 0.16 (see [Supported Zig versions](#supported-zig-versions)).

## Supported Zig versions

Zig has no stability guarantee before 1.0, so zioshade tracks a rolling window rather than a single pin:

- **Floor: Zig 0.15.2.** Anything older fails to compile with a clear message. The floor rarely moves.
- **Tested window: the last three Zig releases**, enforced by the CI matrix. As a new Zig ships it is added and the oldest is eventually dropped from CI (it loses *guaranteed* support but is not deliberately broken).
- **Newer than the window: best effort.** Version-divergent code is isolated in `src/compat.zig` (runtime) and `build_compat.zig` (build), selected by *capability detection* (`@hasDecl`) rather than version numbers, so a release that keeps an API shape works untouched.

Current status: the library, CLI, C ABI, and complete test suite build and pass on both 0.15.2 and 0.16. The `std.Io` / process-API divergence between the two is centralized in `src/compat.zig`. The one remaining 0.16 gap is the standalone developer tools under `tools/` ([#424](https://github.com/zioshade/zioshade/issues/424)); they are not part of the library, CLI, or shipped test steps. Contributors who prefer the pinned toolchain can `mise install` to get 0.15.2.

## Building

```bash
zig build                    # library
zig build cli                # CLI tool
zig build test               # unit tests
zig build strict-gate        # compile-side conformance gate (PASS 2102)
zig build conformance        # spirv-val conformance suite (needs spirv-val on PATH)
zig build fuzz -- --count N  # fuzzer (headline: 1,000,000 clean via `just fuzz-million`)
```

These commands work on **Zig 0.15.2 through 0.16**. For the pinned floor toolchain, `mise install` then `mise exec -- zig ...`, or install 0.15.2 directly from [ziglang.org/download/0.15.2](https://ziglang.org/download/0.15.2/).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and PRs are welcome; please open an issue first for large changes so we can confirm scope. Security issues: [SECURITY.md](SECURITY.md).

## License

Dual-licensed under either of

- [MIT License](LICENSE-MIT)
- [Apache License 2.0](LICENSE-APACHE)

at your option. Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion shall be dual-licensed as above without additional terms.

[^name]: zioshade was formerly named glslpp.
</content>
