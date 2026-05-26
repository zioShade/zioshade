# Examples

End-to-end programs you can run after `zig build`.

| File | What it shows |
|---|---|
| [`glsl_to_hlsl.zig`](glsl_to_hlsl.zig) | Minimal GLSL→SPIR-V→HLSL pipeline, prints the HLSL source. |
| [`reflect_uniforms.zig`](reflect_uniforms.zig) | Compile a GLSL fragment shader, reflect the UBOs and samplers. |

## Running

These examples use glslpp as a sibling package. Build and run them with:

```bash
# from the examples/ directory
zig run glsl_to_hlsl.zig --mod glslpp::../src/root.zig --deps glslpp
zig run reflect_uniforms.zig --mod glslpp::../src/root.zig --deps glslpp
```

Or, when consuming glslpp as a real `build.zig.zon` dependency in your own project, replace the example's `@import("../src/root.zig")` with `@import("glslpp")`.
