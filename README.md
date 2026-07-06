# zioshade

**zioshade** (formerly glslpp), a pure-Zig shading-language compiler: GLSL to SPIR-V to HLSL / MSL / GLSL / WGSL.

[![Sponsor](https://img.shields.io/github/sponsors/deblasis)](https://github.com/sponsors/deblasis)

Extracted from [wintty](https://github.com/deblasis/wintty), a GPU-accelerated terminal emulator, to replace ~60 MB of glslang + SPIRV-Cross C++ dependencies in a single Zig module. No C++ runtime. No system dependencies. No DLL isolation hacks.

> **Scope:** zioshade is **not** a full Khronos drop-in. It is a focused replacement for the shader-compilation surface wintty needs (GLSL 430-class shaders → SPIR-V → backend), validated on the full [`spirv-cross`](https://github.com/KhronosGroup/SPIRV-Cross) and `glslang` reference suites. If you need full GLSL ES, descriptor-set reflection, or SPIRV-Cross-grade WGSL output, **use upstream**. See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) for the full gap analysis.

## Features

- **GLSL → SPIR-V**: Compile GLSL 330–460 shaders to SPIR-V 1.0–1.6
- **SPIR-V → HLSL**: Cross-compile to HLSL Shader Model 6.0 (DX12)
- **SPIR-V → GLSL**: Round-trip / decompile back to GLSL 430
- **SPIR-V → MSL**: Cross-compile to Metal Shading Language 2.0+
- **SPIR-V → WGSL**: Cross-compile to WebGPU Shading Language (shallow coverage — see status doc)
- **Reflection**: Enumerate uniform buffers, inputs/outputs, samplers from SPIR-V (partial — no full descriptor metadata)
- **Kernel fusion / SPIR-V linking**: Merge multiple compute shaders or SPIR-V modules
- **Shadertoy support**: One-shot API for Shadertoy-style fragment shaders
- **Zero C++ dependency**: Pure Zig, builds with `zig build`
- **In-process, threadlocal state only**: Safe to call from multiple threads; no process-wide init/finalize
- **C ABI**: A C header (`include/zioshade.h`) and shared/static libraries are provided for non-Zig consumers (`zig build c-lib`)

## Status

| Metric | Value |
|---|---|
| `spirv-val` conformance | **2076 PASS, 0 spirv-val failures** (`zig build conformance`); 14 known-unsupported constructs honest-error as XFAIL (documented rejections, not failures — see `KNOWN_UNSUPPORTED` in `tests/runner.zig`), 8 skipped, 2098 total — see [docs/STATUS.md](docs/STATUS.md) (generated source of truth) |
| External DXC SPIR-V fixtures | **47 / 51** compile to DXIL (4 limited by DXC's SM 6.1+ / 2 KB structured-buffer cap) |
| WGSL stress tests | **470 / 470** |
| Fuzzer iterations | Structured-GLSL fuzzer clean over **1,000,000** iterations — reproduce with `just fuzz-million` (ad-hoc runs: `zig build fuzz -- --count N`) |
| CI | GitHub Actions workflow committed (3-OS matrix, `.github/workflows/ci.yml`); currently verified locally via `just` (see [Building](#building)) |
| Production use | Backs all shader compilation in [wintty](https://github.com/deblasis/wintty) |

## Quick Start

### CLI

```bash
zig build cli

# GLSL → SPIR-V
zig-out/bin/zioshade compile shader.frag -o shader.spv

# Cross-compile to a backend
zig-out/bin/zioshade hlsl shader.frag -o shader.hlsl
zig-out/bin/zioshade glsl shader.frag -o shader.glsl
zig-out/bin/zioshade msl  shader.frag -o shader.msl
zig-out/bin/zioshade wgsl shader.frag -o shader.wgsl

# With preprocessor defines and include paths
zig-out/bin/zioshade wgsl shader.frag -DDEBUG=1 -DQUALITY=3 -I src/shaders/

# Select entry point for multi-kernel SPIR-V
zig-out/bin/zioshade wgsl module.spv --entry-point compute_blur

# Read from stdin
cat shader.frag | zig-out/bin/zioshade wgsl --stdin

# HLSL with a specific shader model
zig-out/bin/zioshade hlsl shader.frag --shader-model 50

# Reflect a SPIR-V binary
zig-out/bin/zioshade reflect shader.spv

# Validate via spirv-val (if installed on PATH)
zig-out/bin/zioshade validate shader.spv
```

### As a Zig dependency

```zig
// build.zig.zon
.dependencies = .{
    .zioshade = .{
        .url = "https://github.com/deblasis/zioshade/archive/<commit>.tar.gz",
        .hash = "<run zig fetch to get the hash>",
    },
},
```

```zig
// build.zig
const zioshade_dep = b.dependency("zioshade", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zioshade", zioshade_dep.module("zioshade"));
```

```zig
const zioshade = @import("zioshade");

// GLSL → SPIR-V
const spirv = try zioshade.compileToSPIRV(alloc, source, .{
    .stage = .fragment,
    .version = 430,
});
defer alloc.free(spirv);

// SPIR-V → any backend
const hlsl = try zioshade.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
const wgsl = try zioshade.spirvToWGSL(alloc, spirv, .{});

// One-shot: GLSL → backend
const hlsl_one = try zioshade.compileGlslToHlsl(alloc, source, .fragment);
const msl_one  = try zioshade.compileGlslToMsl(alloc, source, .fragment);
const wgsl_one = try zioshade.compileGlslToWgsl(alloc, source, .fragment);

// Reflection
const resources = try zioshade.reflectSPIRV(alloc, spirv);
defer resources.deinit(alloc);
for (resources.uniform_buffers) |ubo| {
    std.debug.print("UBO: {s} (set={d}, binding={d})\n", .{ ubo.name, ubo.set, ubo.binding });
}

// Error handling with diagnostics
var diags = std.ArrayListUnmanaged(zioshade.diagnostic.Diagnostic).empty;
defer {
    for (diags.items) |d| alloc.free(d.message);
    diags.deinit(alloc);
}
_ = zioshade.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags) catch |err| {
    for (diags.items) |d| {
        std.debug.print("{d}:{d}: {s}: {s}\n", .{ d.line, d.column, @tagName(d.kind), d.message });
    }
    return err;
};
```

See [`examples/`](examples/) for runnable end-to-end programs.

## API Surface

### Compilation

| Function | Description |
|---|---|
| `compileToSPIRV(alloc, source, options)` | GLSL → SPIR-V binary words |
| `compileToSPIRVNoOpt(alloc, source, options)` | GLSL → SPIR-V without optimization |
| `compileToSPIRVWithDiagnostics(alloc, source, options, diags)` | GLSL → SPIR-V with collected diagnostics |
| `compileToSPIRVWithFusion(alloc, sources, options, fusion)` | Multiple sources → fused SPIR-V |

### Cross-compilation

| Function | Description |
|---|---|
| `spirvToHLSL(alloc, spirv_words, options)` | SPIR-V → HLSL source |
| `spirvToGLSL(alloc, spirv_words, options)` | SPIR-V → GLSL source |
| `spirvToMSL(alloc, spirv_words, options)` | SPIR-V → MSL source |
| `spirvToWGSL(alloc, spirv_words, options)` | SPIR-V → WGSL source |

### One-shot (GLSL → backend)

| Function | Description |
|---|---|
| `compileGlslToHlsl(alloc, source, stage)` | GLSL → HLSL (null-terminated) |
| `compileGlslToMsl(alloc, source, stage)`  | GLSL → MSL  (null-terminated) |
| `compileGlslToGlsl(alloc, source, stage)` | GLSL → GLSL round-trip |
| `compileGlslToWgsl(alloc, source, stage)` | GLSL → WGSL (null-terminated) |
| `compileShadertoyToHlsl(alloc, source, options)` | Shadertoy-style GLSL → HLSL |

### Utilities

| Function | Description |
|---|---|
| `reflectSPIRV(alloc, spirv_words)` | Enumerate uniforms / samplers / I/O |
| `reflectGLSL(alloc, source, options)` | Compile + reflect convenience |
| `validateSPIRV(alloc, spirv_words)` | Run `spirv-val` if available on `PATH` |
| `linkSPIRVModules(alloc, modules)` | Merge multiple SPIR-V binaries |
| `compileMultiKernel(alloc, sources, options)` | Multiple GLSL → single fused SPIR-V |

## Supported shader stages

| Stage | SPIR-V | HLSL | GLSL | MSL | WGSL |
|---|---|---|---|---|---|
| Vertex | ✅ | ✅ | ✅ | ✅ | ✅ |
| Fragment | ✅ | ✅ | ✅ | ✅ | ✅ |
| Compute | ✅ | ✅ | ✅ | ✅ | ✅ |
| Geometry | ✅ | ✅ | ✅ | ✅ | — |
| Tessellation (TCS / TES) | ✅ | ✅ | ✅ | ✅ | — |
| Mesh / Task | ✅ (basic) | — | — | — | — |
| Ray tracing | ✅ (basic) | — | — | — | — |

## Known limitations

- **GLSL output is 430 only** — other versions are not generated.
- **WGSL backend is shallow** vs SPIRV-Cross — common opcodes only.
- **Cross-compiler control flow:** structured SPIR-V works on every backend; unstructured-but-reducible `if`/`switch` (missing `OpSelectionMerge`) is structurized transparently by a pre-pass. Unstructured loops (missing `OpLoopMerge`) and irreducible CFGs **fail loud** with `error.UnstructuredControlFlow` rather than miscompile. zioshade's own SPIR-V is always structured; this only affects externally-optimized/hand-authored input.
- **Single contributor.** Treat as alpha if you are not the wintty project.

See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) for the complete feature-by-feature comparison against glslang / SPIRV-Cross.

## Performance

Head-to-head against `glslangValidator` + `spirv-cross` invoked as subprocesses (the typical build-pipeline integration), on Windows 11 / Zig 0.15.2 / Vulkan SDK 1.4.341.1, 50 iterations each, `ReleaseFast`:

| Shader | zioshade avg | reference avg | **speedup** | HLSL bytes zioshade / ref |
|---|---:|---:|---:|---:|
| `trivial_frag` | 732 µs | 194 ms | **265×** | 175 / 332 |
| `typical_frag` (UBO + math) | 986 µs | 181 ms | **184×** | 701 / 746 |
| `raymarch` (loop + SDF) | 1.17 ms | 181 ms | **154×** | 1316 / 1562 |
| `simple_compute` (SSBO) | 1.04 ms | 190 ms | **183×** | 516 / 650 |

zioshade is consistently **150–265× faster** for this workflow and produces **5–47% smaller HLSL output**.

> **Caveat:** this compares **in-process zioshade** to **subprocess `glslangValidator` + `spirv-cross`**. Most of the gap is Windows process-spawn overhead — a true library-vs-library comparison (linking `libglslang.a` + `libspirv-cross.a`) is on the roadmap but not yet published. See [BENCHMARKS.md](BENCHMARKS.md) for methodology and how to reproduce.

Reproduce locally:

```bash
zig build bench-compare   # both tools must be on PATH (or set ZIOSHADE_BENCH_GLSLANG / _SPIRVX)
```

## Building

```bash
zig build                  # Library
zig build cli              # CLI tool
zig build test             # Unit tests
zig build conformance      # spirv-val conformance suite (needs spirv-val on PATH)
zig build fuzz -- --count N  # Fuzzer (headline: 1,000,000 clean via `just fuzz-million`)
```

Requires **Zig 0.15.2** (managed via [mise](https://mise.jdx.dev) if `.mise.toml` is honored).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and PRs are welcome — please open an issue first for large changes so we can confirm scope.

## Security

See [SECURITY.md](SECURITY.md) for how to report security issues privately.

## License

Dual-licensed under either of

- [MIT License](LICENSE-MIT)
- [Apache License 2.0](LICENSE-APACHE)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion shall be dual-licensed as above without additional terms.
