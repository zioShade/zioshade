# glslpp

[![Sponsor](https://img.shields.io/github/sponsors/deblasis)](https://github.com/sponsors/deblasis)

A pure-Zig GLSL-to-SPIR-V compiler and cross-compiler, designed as a drop-in replacement for [glslang](https://github.com/KhronosGroup/glslang) + [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) in projects like [wintty](https://github.com/deblasis/wintty).

**No C++ runtime. No system dependencies. No DLL isolation hacks.**

## Features

- **GLSL → SPIR-V**: Compile GLSL 430 / ESSL shaders to SPIR-V 1.0–1.6
- **SPIR-V → HLSL**: Cross-compile SPIR-V to HLSL Shader Model 6.0 (for DX12)
- **SPIR-V → GLSL** (planned): Cross-compile back to GLSL
- **SPIR-V → MSL** (planned): Cross-compile to Metal Shading Language (for macOS)
- **Shadertoy support**: `compileShadertoyToHlsl()` one-shot API for Shadertoy-style shaders
- **Zero C++ dependency**: Pure Zig, compiles with `zig build`
- **Thread-safe**: No global state, no process-wide init/finalize
- **spirv-val conformance**: 548/566 test shaders pass SPIR-V validation

## Quick Start

### As a Zig dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .glslpp = .{
        .url = "https://github.com/deblasis/glslpp/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const glslpp = b.dependency("glslpp", .{
    .target = target,
    .optimize = optimize,
});
const glslpp_mod = glslpp.module("glslpp");
// Add to your executable/module as an import
```

### Usage

```zig
const glslpp = @import("glslpp");

// GLSL → SPIR-V
const spirv = try glslpp.compileToSPIRV(alloc, source, .{
    .stage = .fragment,
    .version = 430,
});

// SPIR-V → HLSL
const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{});

// One-shot Shadertoy → HLSL
const result = try glslpp.compileShadertoyToHlsl(alloc, glsl_source, .{});
```

## API

| Function | Description |
|---|---|
| `compileToSPIRV(alloc, source, options)` | GLSL → SPIR-V binary words |
| `compileToSPIRVWithDiagnostics(alloc, source, options, diags)` | GLSL → SPIR-V with error collection |
| `spirvToHLSL(alloc, spirv_words, options)` | SPIR-V → HLSL source |
| `spirvToGLSL(alloc, spirv_words, options)` | SPIR-V → GLSL source (planned) |
| `compileShadertoyToHlsl(alloc, glsl, options)` | Shadertoy GLSL → HLSL one-shot |

## Supported Shader Stages

| Stage | Status |
|---|---|
| Vertex | ✅ |
| Fragment | ✅ |
| Compute | ✅ |
| Geometry | ✅ |
| Tessellation Control | ✅ |
| Tessellation Evaluation | ✅ |
| Mesh / Task | ❌ Not supported |

## Building

```bash
zig build              # Build the library
zig build test         # Run unit tests
zig build conformance  # Run shader conformance tests (requires spirv-val)
```

## License

Licensed under either of

- MIT License ([LICENSE-MIT](LICENSE-MIT))
- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you shall be dual licensed as above, without any additional terms or conditions.
