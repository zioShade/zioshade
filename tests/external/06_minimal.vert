// SPDX-License-Identifier: MIT OR Apache-2.0
// Minimal vertex shader: passes through position.
// Post-M5.0 (2026-05-27) the HLSL backend emits a valid `VS_OUTPUT
// main(VS_INPUT input)` signature with `gl_Position : SV_Position`. SPIR-V,
// GLSL, MSL, WGSL, and HLSL all round-trip successfully.
#version 450

layout(location = 0) in vec3 in_pos;

void main() {
    gl_Position = vec4(in_pos, 1.0);
}
