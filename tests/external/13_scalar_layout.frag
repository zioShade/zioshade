// SPDX-License-Identifier: MIT OR Apache-2.0
// GL_EXT_scalar_block_layout: UBO with vec3 + float packed tightly (M8.1).
// Expected: SPIR-V compiles with scalar packing; cross-compile backends may
// emit standard layouts and still pass naga / glslpp validation.
#version 450
#extension GL_EXT_scalar_block_layout : require

layout(set = 0, binding = 0, scalar) uniform Params {
    vec3 dir;
    float intensity;
    vec3 tint;
    float bias;
} params;

layout(location = 0) out vec4 fragColor;

void main() {
    fragColor = vec4(params.dir * params.intensity + params.tint, params.bias);
}
