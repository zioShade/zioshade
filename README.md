# glslpp

[![Sponsor](https://img.shields.io/github.com/sponsors/deblasis)](https://github.com/sponsors/deblasis)

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
- **DXC-validated**: HLSL output compiles with DXC for Shader Model 6.0

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
const glslpp_dep = b.dependency("glslpp", .{
    .target = target,
    .optimize = optimize,
});
step.root_module.addImport("glslpp", glslpp_dep.module("glslpp"));
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
const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{
    .binding_shift = -1,  // remap binding=1 → register(b0)
    .shader_model = 60,   // Shader Model 6.0
});

// One-shot GLSL → HLSL (for wintty/shadertoy integration)
const hlsl = try glslpp.compileGlslToHlsl(alloc, glsl_source, .fragment);
```

## Integration with wintty (Ghostty)

glslpp is designed as a drop-in replacement for glslang + SPIRV-Cross in wintty's
shadertoy shader pipeline:

1. Add glslpp to your `build.zig.zon` dependencies
2. Replace the `shader_wrapper.dll` path with `glslpp.compileGlslToHlsl()`
3. HLSL path no longer needs the 8MB stack thread spawn or MSVC-compiled DLL

Benefits:
- **~3.6ms** average compilation time per shader (50-iteration benchmark)
- **No C++ runtime** — eliminates DLL isolation hacks
- **No thread spawn** — glslpp is pure Zig, safe to call from any thread
- **DXC-validated** output — 0 errors, 0 warnings on the CRT test shader

## API

| Function | Description |
|---|---|
| `compileToSPIRV(alloc, source, options)` | GLSL → SPIR-V binary words |
| `compileToSPIRVWithDiagnostics(alloc, source, options, diags)` | GLSL → SPIR-V with error collection |
| `spirvToHLSL(alloc, spirv_words, options)` | SPIR-V → HLSL source |
| `compileGlslToHlsl(alloc, glsl_source, stage)` | One-shot GLSL → HLSL (for wintty) |
| `compileShadertoyToHlsl(alloc, glsl, options)` | Shadertoy GLSL → HLSL one-shot |
| `spirvToGLSL(alloc, spirv_words, options)` | SPIR-V → GLSL source (planned) |

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
zig build test-hlsl    # Run HLSL backend tests (128 tests)
zig build bench        # Run wintty shader benchmark
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
