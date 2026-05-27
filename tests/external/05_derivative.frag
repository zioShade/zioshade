// SPDX-License-Identifier: MIT OR Apache-2.0
// Derivative builtins: dFdx / dFdy / fwidth on screen-space UV.
// Expected: all 4 backends emit successfully (WGSL uses dpdx/dpdy).
#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 fragColor;

void main() {
    vec2 dx = dFdx(in_uv);
    vec2 dy = dFdy(in_uv);
    float w = fwidth(in_uv.x);
    fragColor = vec4(dx, dy.x, w);
}
