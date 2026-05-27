// SPDX-License-Identifier: MIT OR Apache-2.0
// UBO with multiple fields: scalar, vec2, vec4.
// Expected: all 4 backends emit successfully.
#version 450

layout(set = 0, binding = 0, std140) uniform Material {
    vec4 tint;
    vec2 uv_scale;
    float intensity;
} material;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = in_uv * material.uv_scale;
    fragColor = material.tint * material.intensity * vec4(uv, 0.0, 1.0);
}
