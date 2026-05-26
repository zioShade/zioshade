# Examples

End-to-end programs that link against the public `glslpp` module.

| File | What it shows |
|---|---|
| [`glsl_to_hlsl.zig`](glsl_to_hlsl.zig) | Minimal GLSL → SPIR-V → HLSL pipeline, prints the HLSL source. |
| [`reflect_uniforms.zig`](reflect_uniforms.zig) | Compile a GLSL fragment shader, reflect the UBOs and samplers. |

## Build & run

```bash
zig build examples
zig-out/bin/example-glsl_to_hlsl
zig-out/bin/example-reflect_uniforms
```

The examples are wired up in [`build.zig`](../build.zig) as real installable artifacts that import the `glslpp` module, so CI will catch any API drift.

## Using glslpp from your own project

Add glslpp to your `build.zig.zon`:

```zig
.dependencies = .{
    .glslpp = .{
        .url = "https://github.com/deblasis/glslpp/archive/<commit>.tar.gz",
        .hash = "<run zig fetch to get the hash>",
    },
},
```

Then in your `build.zig`:

```zig
const glslpp_dep = b.dependency("glslpp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("glslpp", glslpp_dep.module("glslpp"));
```

The example sources are exactly what you'd write in your own program — `@import("glslpp")` and use the API.
