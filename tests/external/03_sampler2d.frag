// SPDX-License-Identifier: MIT OR Apache-2.0
// Textured fragment shader with a combined sampler2D.
// Expected: all 4 backends emit successfully.
#version 450

layout(set = 0, binding = 0) uniform sampler2D tex;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 fragColor;

void main() {
    fragColor = texture(tex, in_uv);
}
