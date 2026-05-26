# glslpp

[![Sponsor](https://img.shields.io/github/sponsors/deblasis)](https://github.com/sponsors/deblasis)

A pure-Zig GLSL → SPIR-V compiler and SPIR-V cross-compiler (HLSL / MSL / GLSL / WGSL).

Extracted from [wintty](https://github.com/deblasis/wintty), a GPU-accelerated terminal emulator, to replace ~60 MB of glslang + SPIRV-Cross C++ dependencies in a single Zig module. No C++ runtime. No system dependencies. No DLL isolation hacks.

> **Scope:** glslpp is **not** a full Khronos drop-in. It is a focused replacement for the shader-compilation surface wintty needs (GLSL 430-class shaders → SPIR-V → backend), validated on the full [`spirv-cross`](https://github.com/KhronosGroup/SPIRV-Cross) and `glslang` reference suites. If you need full GLSL ES, descriptor-set reflection, specialization constants, or SPIRV-Cross-grade WGSL output, **use upstream**. See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) for the full gap analysis.

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

## Status

| Metric | Value |
|---|---|
| `spirv-val` conformance | **2,087 / 2,087** runnable fixtures pass (`zig build conformance`) — see [docs/TEST_COVERAGE.md](docs/TEST_COVERAGE.md) |
| External DXC SPIR-V fixtures | **47 / 51** compile to DXIL (4 limited by DXC's SM 6.1+ / 2 KB structured-buffer cap) |
| WGSL stress tests | **470 / 470** |
| Fuzzer iterations (ad-hoc, no CI yet) | 50,000 crash-free — reproduce with `zig build fuzz -- --count 50000` |
| CI | Not yet wired up; cross-platform builds unverified by automation |
| Production use | Backs all shader compilation in [wintty](https://github.com/deblasis/wintty) |

## Quick Start

### CLI

```bash
zig build cli

# GLSL → SPIR-V
zig-out/bin/glslpp compile shader.frag -o shader.spv

# Cross-compile to a backend
zig-out/bin/glslpp hlsl shader.frag -o shader.hlsl
zig-out/bin/glslpp glsl shader.frag -o shader.glsl
zig-out/bin/glslpp msl  shader.frag -o shader.msl
zig-out/bin/glslpp wgsl shader.frag -o shader.wgsl

# With preprocessor defines and include paths
zig-out/bin/glslpp wgsl shader.frag -DDEBUG=1 -DQUALITY=3 -I src/shaders/

# Select entry point for multi-kernel SPIR-V
zig-out/bin/glslpp wgsl module.spv --entry-point compute_blur

# Read from stdin
cat shader.frag | zig-out/bin/glslpp wgsl --stdin

# HLSL with a specific shader model
zig-out/bin/glslpp hlsl shader.frag --shader-model 50

# Reflect a SPIR-V binary
zig-out/bin/glslpp reflect shader.spv

# Validate via spirv-val (if installed on PATH)
zig-out/bin/glslpp validate shader.spv
```

### As a Zig dependency

```zig
// build.zig.zon
.dependencies = .{
    .glslpp = .{
        .url = "https://github.com/deblasis/glslpp/archive/<commit>.tar.gz",
        .hash = "<run zig fetch to get the hash>",
    },
},
```

```zig
// build.zig
const glslpp_dep = b.dependency("glslpp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("glslpp", glslpp_dep.module("glslpp"));
```

```zig
const glslpp = @import("glslpp");

// GLSL → SPIR-V
const spirv = try glslpp.compileToSPIRV(alloc, source, .{
    .stage = .fragment,
    .version = 430,
});
defer alloc.free(spirv);

// SPIR-V → any backend
const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});

// One-shot: GLSL → backend
const hlsl_one = try glslpp.compileGlslToHlsl(alloc, source, .fragment);
const msl_one  = try glslpp.compileGlslToMsl(alloc, source, .fragment);
const wgsl_one = try glslpp.compileGlslToWgsl(alloc, source, .fragment);

// Reflection
const resources = try glslpp.reflectSPIRV(alloc, spirv);
defer resources.deinit(alloc);
for (resources.uniform_buffers) |ubo| {
    std.debug.print("UBO: {s} (set={d}, binding={d})\n", .{ ubo.name, ubo.set, ubo.binding });
}

// Error handling with diagnostics
var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
defer {
    for (diags.items) |d| alloc.free(d.message);
    diags.deinit(alloc);
}
_ = glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags) catch |err| {
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

- **No specialization constants** (`OpSpecConstant*`).
- **GLSL output is 430 only** — other versions are not generated.
- **WGSL backend is shallow** vs SPIRV-Cross — common opcodes only.
- **Cross-compiler control flow requires `OpSelectionMerge`.** SPIR-V produced by glslpp itself always satisfies this; externally-produced or post-optimized SPIR-V without merge info will get an empty branch body and a stderr warning.
- **No formal C ABI.** Consumers outside the Zig ecosystem must write their own FFI layer.
- **Single contributor.** Treat as alpha if you are not the wintty project.

See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) for the complete feature-by-feature comparison against glslang / SPIRV-Cross.

## Performance

Head-to-head against `glslangValidator` + `spirv-cross` invoked as subprocesses (the typical build-pipeline integration), on Windows 11 / Zig 0.15.2 / Vulkan SDK 1.4.341.1, 50 iterations each, `ReleaseFast`:

| Shader | glslpp avg | reference avg | **speedup** | HLSL bytes glslpp / ref |
|---|---:|---:|---:|---:|
| `trivial_frag` | 732 µs | 194 ms | **265×** | 175 / 332 |
| `typical_frag` (UBO + math) | 986 µs | 181 ms | **184×** | 701 / 746 |
| `raymarch` (loop + SDF) | 1.17 ms | 181 ms | **154×** | 1316 / 1562 |
| `simple_compute` (SSBO) | 1.04 ms | 190 ms | **183×** | 516 / 650 |

glslpp is consistently **150–265× faster** for this workflow and produces **5–47% smaller HLSL output**.

> **Caveat:** this compares **in-process glslpp** to **subprocess `glslangValidator` + `spirv-cross`**. Most of the gap is Windows process-spawn overhead — a true library-vs-library comparison (linking `libglslang.a` + `libspirv-cross.a`) is on the roadmap but not yet published. See [BENCHMARKS.md](BENCHMARKS.md) for methodology and how to reproduce.

Reproduce locally:

```bash
zig build bench-compare   # both tools must be on PATH (or set GLSLPP_BENCH_GLSLANG / _SPIRVX)
```

## Building

```bash
zig build                  # Library
zig build cli              # CLI tool
zig build test             # Unit tests
zig build conformance      # spirv-val conformance suite (needs spirv-val on PATH)
zig build fuzz -- --count 50000  # Fuzzer
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
