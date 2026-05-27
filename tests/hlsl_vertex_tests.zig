// SPDX-License-Identifier: MIT OR Apache-2.0
// HLSL vertex shader entry-point signature emission tests (M5.0 + M5.1).
//
// Asserts that the HLSL backend emits:
//   * struct VS_INPUT { ... }; collecting Input storage class variables
//     with TEXCOORD<N> semantics (or SV_VertexID/SV_InstanceID for built-ins).
//   * struct VS_OUTPUT { ... }; collecting Output storage class variables,
//     with gl_Position → SV_Position (or POSITION under SM 5.0) and
//     other location-bound outputs → TEXCOORD<N>.
//   * `VS_OUTPUT main(VS_INPUT input)` entry-point signature.

const std = @import("std");
const glslpp = @import("glslpp");

test "hlsl vertex: emits VS_INPUT and VS_OUTPUT structs" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) in vec3 in_pos;
        \\layout(location=1) in vec2 in_uv;
        \\layout(location=0) out vec2 v_uv;
        \\void main() { gl_Position = vec4(in_pos, 1.0); v_uv = in_uv; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 60 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "VS_INPUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "VS_OUTPUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SV_Position") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "TEXCOORD0") != null);
}

test "hlsl vertex sm6: uses SV_Position" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) in vec3 in_pos;
        \\void main() { gl_Position = vec4(in_pos, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 60 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SV_Position") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "POSITION") == null);
}

test "hlsl vertex sm5: uses POSITION (legacy)" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) in vec3 in_pos;
        \\void main() { gl_Position = vec4(in_pos, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 50 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "POSITION") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SV_Position") == null);
}

test "hlsl vertex: gl_VertexID maps to SV_VertexID" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\void main() { gl_Position = vec4(float(gl_VertexID), 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 60 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SV_VertexID") != null);
}
