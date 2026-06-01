#version 450
// Regression guard: WGSL textureGather takes the component as the FIRST arg —
// textureGather(component, texture, sampler, coords). glslpp previously emitted
// GLSL order (tex, sampler, coords, component), so naga read the texture where
// it expects the integer component ("must resolve to u32 or i32").
layout(binding = 0) uniform sampler2D uTex;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 o;
void main() { o = textureGather(uTex, uv, 0); }
