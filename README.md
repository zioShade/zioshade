# glslpp

[![Sponsor](https://img.shields.io/github/sponsors/deblasis)](https://github.com/sponsors/deblasis)

A pure-Zig GLSL-to-SPIR-V compiler and cross-compiler. Drop-in replacement for [glslang](https://github.com/KhronosGroup/glslang) + [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross).

**No C++ runtime. No system dependencies. No DLL isolation hacks.**

## Features

- **GLSL → SPIR-V**: Compile GLSL 330–460 / ESSL shaders to SPIR-V 1.0–1.6
- **SPIR-V → HLSL**: Cross-compile to HLSL Shader Model 5.0+ (for DX12)
- **SPIR-V → GLSL**: Round-trip / decompile back to GLSL 330–460
- **SPIR-V → MSL**: Cross-compile to Metal Shading Language 2.1+ (for macOS/iOS)
- **SPIR-V → WGSL**: Cross-compile to WebGPU Shading Language
- **Reflection**: Extract uniform buffers, inputs/outputs, samplers from SPIR-V
- **Kernel Fusion**: Merge multiple compute shaders to reduce bandwidth
- **SPIR-V Linking**: Merge multiple SPIR-V modules into one
- **Shadertoy support**: One-shot API for Shadertoy-style shaders
- **Zero C++ dependency**: Pure Zig, compiles with `zig build`
- **Thread-safe**: No global state, no process-wide init/finalize

## Quick Start

### As a Zig dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .glslpp = .{
        .url = "https://github.com/deblasis/glslpp/archive/<commit>.tar.gz",
        .hash = "<run zig fetch to get hash>",
    },
},
```

Then in your `build.zig`:

```zig
const glslpp_dep = b.dependency("glslpp", .{
    .target = target,
    .optimize = optimize,
});
step.root_module.addImport("glslpp", glslpp_dep.module("glslpp"));
```

### CLI

```bash
# Build the CLI
zig build cli

# Compile GLSL to SPIR-V
zig-out/bin/glslpp compile shader.frag -o shader.spv

# Cross-compile to all targets
zig-out/bin/glslpp hlsl shader.frag -o shader.hlsl
zig-out/bin/glslpp glsl shader.frag -o shader.glsl
zig-out/bin/glslpp msl shader.frag -o shader.msl
zig-out/bin/glslpp wgsl shader.frag -o shader.wgsl

# With preprocessor defines and include paths
zig-out/bin/glslpp wgsl shader.frag -DDEBUG=1 -DQUALITY=3 -I src/shaders/

# Select entry point for multi-kernel SPIR-V
zig-out/bin/glslpp wgsl module.spv --entry-point compute_blur

# Read from stdin
cat shader.frag | zig-out/bin/glslpp wgsl --stdin

# HLSL with specific shader model
zig-out/bin/glslpp hlsl shader.frag --shader-model 50

# Reflect on a SPIR-V binary
zig-out/bin/glslpp reflect shader.spv

# Validate with spirv-val
zig-out/bin/glslpp validate shader.spv
```

### Library Usage

```zig
const glslpp = @import("glslpp");

// GLSL → SPIR-V
const spirv = try glslpp.compileToSPIRV(alloc, source, .{
    .stage = .fragment,
    .version = 430,
});

// SPIR-V → any backend
const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});

// One-shot: GLSL → any backend
const hlsl = try glslpp.compileGlslToHlsl(alloc, source, .fragment);
const msl = try glslpp.compileGlslToMsl(alloc, source, .fragment);
const wgsl = try glslpp.compileGlslToWgsl(alloc, source, .fragment);
const glsl = try glslpp.compileGlslToGlsl(alloc, source, .fragment);

// Reflection
const resources = try glslpp.reflectSPIRV(alloc, spirv);
defer resources.deinit(alloc);
for (resources.uniform_buffers) |ubo| {
    std.debug.print("UBO: {s} (set={d}, binding={d})\n", .{ubo.name, ubo.set, ubo.binding});
}

// Error handling with diagnostics
var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
defer {
    for (diags.items) |d| alloc.free(d.message);
    diags.deinit(alloc);
}
const result = glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{.stage = .fragment}, &diags) catch |err| {
    for (diags.items) |d| {
        std.debug.print("{d}:{d}: {s}: {s}\n", .{d.line, d.column, @tagName(d.kind), d.message});
    }
    return err;
};
```

## API Reference

### Compilation

| Function | Description |
|---|---|
| `compileToSPIRV(alloc, source, options)` | GLSL → SPIR-V binary words |
| `compileToSPIRVNoOpt(alloc, source, options)` | GLSL → SPIR-V without optimization |
| `compileToSPIRVWithDiagnostics(alloc, source, options, diags)` | GLSL → SPIR-V with error collection |
| `compileToSPIRVWithFusion(alloc, sources, options, fusion)` | Multiple sources → fused SPIR-V |

### Cross-Compilation

| Function | Description |
|---|---|
| `spirvToHLSL(alloc, spirv_words, options)` | SPIR-V → HLSL source |
| `spirvToGLSL(alloc, spirv_words, options)` | SPIR-V → GLSL source |
| `spirvToMSL(alloc, spirv_words, options)` | SPIR-V → MSL source |
| `spirvToWGSL(alloc, spirv_words, options)` | SPIR-V → WGSL source |

### One-Shot (GLSL → Target)

| Function | Description |
|---|---|
| `compileGlslToHlsl(alloc, source, stage)` | GLSL → HLSL (null-terminated) |
| `compileGlslToMsl(alloc, source, stage)` | GLSL → MSL (null-terminated) |
| `compileGlslToGlsl(alloc, source, stage)` | GLSL → GLSL round-trip |
| `compileGlslToWgsl(alloc, source, stage)` | GLSL → WGSL (null-terminated) |
| `compileShadertoyToHlsl(alloc, source, options)` | Shadertoy GLSL → HLSL |

### Utilities

| Function | Description |
|---|---|
| `reflectSPIRV(alloc, spirv_words)` | Extract shader resources from SPIR-V |
| `reflectGLSL(alloc, source, options)` | Compile + reflect convenience |
| `validateSPIRV(alloc, spirv_words)` | Validate via spirv-val (returns bool) |
| `linkSPIRVModules(alloc, modules)` | Merge multiple SPIR-V binaries |
| `compileMultiKernel(alloc, sources, options)` | Multiple GLSL → single SPIR-V |

## Supported Shader Stages

| Stage | SPIR-V | HLSL | GLSL | MSL | WGSL |
|---|---|---|---|---|---|
| Vertex | ✅ | ✅ | ✅ | ✅ | ✅ |
| Fragment | ✅ | ✅ | ✅ | ✅ | ✅ |
| Compute | ✅ | ✅ | ✅ | ✅ | ✅ |
| Geometry | ✅ | ✅ | ✅ | ✅ | — |
| Tessellation | ✅ | ✅ | ✅ | ✅ | — |
| Mesh / Task | ✅ | — | — | — | — |
| Ray Tracing | ✅ | — | — | — | — |

## Conformance

- **1811/1811** shaders pass `spirv-val` validation
- **51/51** external DXC SPIR-V binaries cross-validated across all backends
- **180/180** WGSL outputs validated through naga
- **50,000** fuzz iterations crash-free across all backends

## Building

```bash
zig build              # Build the library
zig build cli          # Build the CLI tool
zig build test         # Run all tests
zig build conformance  # Run shader conformance tests (requires spirv-val)
```

## Performance

Benchmarked with the wintty CRT shadertoy shader (50 iterations, ReleaseFast):

```
Avg total: ~3.6ms
Min total: ~2.7ms
SPIR-V:   1691 words (6.6 KB)
HLSL:     5800 bytes (5.7 KB)
```

## License

Licensed under either of

- MIT License ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you shall be dual licensed as above, without any additional terms or conditions.
