// SPDX-License-Identifier: MIT OR Apache-2.0
// Specialization constant used as a loop bound (exercises M3.4/M3.5).
// Expected: all 4 backends emit successfully.
#version 450

layout(constant_id = 0) const int N = 4;

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 fragColor;

void main() {
    vec4 acc = vec4(0.0);
    for (int i = 0; i < N; ++i) {
        acc += vec4(in_uv, float(i), 1.0);
    }
    fragColor = acc / float(N);
}
