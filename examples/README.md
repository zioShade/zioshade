# Examples

End-to-end programs that link against the public `zioshade` module.

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

The examples are wired up in [`build.zig`](../build.zig) as real installable artifacts that import the `zioshade` module, so CI will catch any API drift.

## Using zioshade from your own project

Add zioshade to your `build.zig.zon`:

```zig
.dependencies = .{
    .zioshade = .{
        .url = "https://github.com/zioshade/zioshade/archive/<commit>.tar.gz",
        .hash = "<run zig fetch to get the hash>",
    },
},
```

Then in your `build.zig`:

```zig
const zioshade_dep = b.dependency("zioshade", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zioshade", zioshade_dep.module("zioshade"));
```

The example sources are exactly what you'd write in your own program — `@import("zioshade")` and use the API.
