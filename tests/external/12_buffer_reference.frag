// SPDX-License-Identifier: MIT OR Apache-2.0
// Buffer-reference pointer access (M8.2: GL_EXT_buffer_reference recognition).
// Compiles to SPIR-V with PhysicalStorageBufferAddresses; cross-compile to
// non-Vulkan backends may fail because the feature isn't part of WGSL/MSL/HLSL.
// Expected: SPIR-V passes; other backends may report a known limitation.
#version 450
#extension GL_EXT_buffer_reference : require

layout(buffer_reference, std430) readonly buffer FloatRef {
    float v;
};

layout(set = 0, binding = 0) uniform U {
    FloatRef ref;
} u;

layout(location = 0) out vec4 fragColor;

void main() {
    fragColor = vec4(u.ref.v);
}
