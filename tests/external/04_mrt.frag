// SPDX-License-Identifier: MIT OR Apache-2.0
// MRT fragment: 3 output render targets via location=0/1/2.
// Expected: all 4 backends emit successfully.
#version 450

layout(location = 0) in vec3 in_normal;
layout(location = 1) in vec3 in_albedo;

layout(location = 0) out vec4 gbuffer_albedo;
layout(location = 1) out vec4 gbuffer_normal;
layout(location = 2) out vec4 gbuffer_pos;

void main() {
    gbuffer_albedo = vec4(in_albedo, 1.0);
    gbuffer_normal = vec4(normalize(in_normal) * 0.5 + 0.5, 0.0);
    gbuffer_pos = vec4(gl_FragCoord.xyz, 1.0);
}
