// SPDX-License-Identifier: MIT OR Apache-2.0
// Minimal vertex shader: passes through position.
// NOTE: HLSL backend doesn't yet emit a valid vertex entry signature
//       (tracked as M5.0 in the roadmap). HLSL cross-compile is expected to fail.
//       SPIR-V, GLSL, MSL, and WGSL should all succeed.
#version 450

layout(location = 0) in vec3 in_pos;

void main() {
    gl_Position = vec4(in_pos, 1.0);
}
