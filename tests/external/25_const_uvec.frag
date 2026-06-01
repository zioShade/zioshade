#version 450
// Regression guard: a constant unsigned vector (uvec2(7u,15u)) used in a bitwise
// op. The WGSL constant-composite builder emitted a GLSL-style constructor name
// (`uint2(...)` / `uvec2i(...)`) that naga rejects as an undefined identifier;
// it must be a WGSL vector constructor `vec2<u32>(...)`.
layout(location = 0) in vec2 v;
layout(location = 0) out vec4 o;
void main() {
    uvec2 a = uvec2(v) & uvec2(7u, 15u);
    o = vec4(vec2(a), 0.0, 1.0);
}
