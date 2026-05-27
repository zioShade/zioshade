// SPDX-License-Identifier: MIT OR Apache-2.0
// Vertex shader with multiple location-bound input attributes.
// NOTE: HLSL vertex signature is an M5.0 known limitation.
// SPIR-V, GLSL, MSL, WGSL should succeed.
#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_color;

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec4 v_color;

void main() {
    v_normal = in_normal;
    v_uv = in_uv;
    v_color = in_color;
    gl_Position = vec4(in_pos, 1.0);
}
