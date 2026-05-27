// SPDX-License-Identifier: MIT OR Apache-2.0
// Baseline fragment shader: writes a constant color.
// Expected: all 4 backends emit successfully.
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    fragColor = vec4(1.0);
}
