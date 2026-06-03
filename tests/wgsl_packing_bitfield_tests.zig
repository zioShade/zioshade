// SPDX-License-Identifier: MIT OR Apache-2.0
//! M4 — WGSL backend tests for GLSL packing (54-64) and SPIR-V bitfield
//! (201/202/203) opcodes. The names emitted by the WGSL backend differ from
//! their GLSL.std.450 counterparts (pack2x16snorm vs packSnorm2x16, etc.).
const std = @import("std");
const glslpp = @import("glslpp");

fn compileWgsl(alloc: std.mem.Allocator, src: [:0]const u8, stage: glslpp.Stage) ![]const u8 {
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = stage });
    defer alloc.free(spv);
    return try glslpp.spirvToWGSL(alloc, spv, .{});
}

// ── M4.1: packing ──

// The gl_Position write in these vertex shaders is load-bearing: WGSL requires
// every vertex entry to return a @builtin(position), and the backend fails loud
// (error.UnsupportedOp) on a vertex shader that lacks one rather than fabricate
// it (see spirv_to_wgsl.zig honest-error guard). These tests only care about the
// packSnorm2x16/packHalf2x16 → pack2x16snorm/pack2x16float name mapping, but the
// shader must still be lowerable to exercise it.
test "M4.1 WGSL: packSnorm2x16 emits pack2x16snorm" {
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) flat out uint packed_uv;
        \\void main() { packed_uv = packSnorm2x16(uv); gl_Position = vec4(uv, 0.0, 1.0); }
    , .vertex);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "pack2x16snorm") != null);
}

test "M4.1 WGSL: packHalf2x16 emits pack2x16float" {
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) flat out uint packed_uv;
        \\void main() { packed_uv = packHalf2x16(uv); gl_Position = vec4(uv, 0.0, 1.0); }
    , .vertex);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "pack2x16float") != null);
}

test "M4.1 WGSL: unpackHalf2x16 emits unpack2x16float" {
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) flat in uint packed_uv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(unpackHalf2x16(packed_uv), 0.0, 1.0); }
    , .fragment);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "unpack2x16float") != null);
}

test "M4.1 WGSL: packUnorm2x16 + unpackUnorm2x16 round-trip emits both intrinsics" {
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    uint p = packUnorm2x16(uv);
        \\    vec2 q = unpackUnorm2x16(p);
        \\    fragColor = vec4(q, 0.0, 1.0);
        \\}
    , .fragment);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "pack2x16unorm") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "unpack2x16unorm") != null);
}

// ── Integer user-defined IO must be @interpolate(flat) ──
//
// WGSL requires any integer-typed (scalar/vector of i32/u32) user-defined vertex
// output or fragment input to carry @interpolate(flat): perspective/linear
// interpolation of integers is undefined, so wgpu/Dawn reject a pipeline whose
// integer varying lacks it. GLSL already forces such varyings `flat` (lowered to
// a SPIR-V Flat decoration), so the source intent survives into SPIR-V. The
// attribute is, however, ILLEGAL on vertex *inputs* (attributes are fetched, not
// interpolated), so an integer/float vertex attribute must stay bare.
test "WGSL: integer vertex output carries @interpolate(flat)" {
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) flat out uint packed_uv;
        \\void main() { packed_uv = packSnorm2x16(uv); gl_Position = vec4(uv, 0.0, 1.0); }
    , .vertex);
    defer alloc.free(wgsl);
    // The u32 output field is flat-interpolated (field-specific match so a
    // future regression that mis-targets the attribute is caught)...
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@interpolate(flat) packed_uv: u32") != null);
    // ...while the vec2f vertex-attribute input stays bare (interpolation
    // attributes are illegal on vertex inputs).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(0) uv: vec2f") != null);
}

test "WGSL: integer fragment input carries @interpolate(flat)" {
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) flat in uint packed_uv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(unpackHalf2x16(packed_uv), 0.0, 1.0); }
    , .fragment);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@interpolate(flat) packed_uv: u32") != null);
}

test "WGSL: integer-vector fragment input carries @interpolate(flat)" {
    // Exercises isIntegerWgslType's vector arm (ivec2 -> vec2i): the most
    // error-prone part of the fix (the type-name list), untouched by the scalar
    // `uint` cases above.
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) flat in ivec2 cell;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(cell.x), float(cell.y), 0.0, 1.0); }
    , .fragment);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@interpolate(flat) cell: vec2i") != null);
}

test "WGSL: flat-qualified float varying carries @interpolate(flat)" {
    // A `flat`-qualified FLOAT varying is non-integer, so this passes ONLY via
    // the SPIR-V Flat-decoration arm of the `hasDec(.flat) or isIntegerWgslType`
    // condition — guarding that branch independently of integer-type detection.
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) flat out float weight;
        \\void main() { weight = uv.x; gl_Position = vec4(uv, 0.0, 1.0); }
    , .vertex);
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@interpolate(flat) weight: f32") != null);
}

test "WGSL: smooth float varying is NOT given @interpolate(flat)" {
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec2 texCoord;
        \\void main() { texCoord = uv; gl_Position = vec4(uv, 0.0, 1.0); }
    , .vertex);
    defer alloc.free(wgsl);
    // A default (smooth) float varying must not gain an interpolation attribute.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@interpolate") == null);
}

// ── M4.2: bitfield ──
//
// glslpp's semantic layer doesn't accept `bitfieldInsert`/`bitfieldExtract`
// directly (would need GLSL 400+ built-in registration), so we test the
// WGSL emitter via hand-crafted SPIR-V containing OpBitFieldInsert (201)
// and OpBitFieldUExtract (203).

test "M4.2 WGSL: OpBitFieldInsert emits insertBits" {
    const alloc = std.testing.allocator;
    // Minimal SPIR-V exposing a single OpBitFieldInsert in a fragment shader.
    // Layout: header, capabilities, entry-point, types, vars, function with
    // one OpBitFieldInsert instruction. Hand-built so we exercise only the
    // emitter for opcode 201.
    const words = [_]u32{
        0x07230203, // magic
        0x00010000, // version 1.0
        0x000d000d, // generator
        20,         // ID bound
        0,          // schema
        // OpCapability Shader (17, wc=2)
        (2 << 16) | 17, 1,
        // OpMemoryModel Logical GLSL450 (14, wc=3)
        (3 << 16) | 14, 0, 1,
        // OpEntryPoint Fragment %2 "main" (15, wc=5)
        (5 << 16) | 15, 4, 2, 0x6e69616d, 0x00000000,
        // OpExecutionMode %2 OriginUpperLeft (16, wc=3)
        (3 << 16) | 16, 2, 7,
        // OpName %2 "main" (5, wc=4)
        (4 << 16) | 5, 2, 0x6e69616d, 0x00000000,
        // %3 = OpTypeVoid (19, wc=2)
        (2 << 16) | 19, 3,
        // %4 = OpTypeFunction %3 (33, wc=3)
        (3 << 16) | 33, 4, 3,
        // %5 = OpTypeInt 32 0 (unsigned) (21, wc=4)
        (4 << 16) | 21, 5, 32, 0,
        // %6 = OpConstant %5 0xFF00 (43, wc=4)
        (4 << 16) | 43, 5, 6, 0xFF00,
        // %7 = OpConstant %5 0xAB (43, wc=4)
        (4 << 16) | 43, 5, 7, 0xAB,
        // %8 = OpConstant %5 8 (43, wc=4)
        (4 << 16) | 43, 5, 8, 8,
        // %9 = OpConstant %5 8 (43, wc=4)
        (4 << 16) | 43, 5, 9, 8,
        // %2 = OpFunction %3 None %4 (54, wc=5)
        (5 << 16) | 54, 3, 2, 0, 4,
        // OpLabel %10 (248, wc=2)
        (2 << 16) | 248, 10,
        // %11 = OpBitFieldInsert %5 %6 %7 %8 %9 (201, wc=7)
        (7 << 16) | 201, 5, 11, 6, 7, 8, 9,
        // OpReturn (253, wc=1)
        (1 << 16) | 253,
        // OpFunctionEnd (56, wc=1)
        (1 << 16) | 56,
    };
    const wgsl = try glslpp.spirvToWGSL(alloc, &words, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "insertBits(") != null);
}

test "M4.2 WGSL: OpBitFieldUExtract emits extractBits" {
    const alloc = std.testing.allocator;
    const words = [_]u32{
        0x07230203,
        0x00010000,
        0x000d000d,
        20,
        0,
        (2 << 16) | 17, 1,
        (3 << 16) | 14, 0, 1,
        (5 << 16) | 15, 4, 2, 0x6e69616d, 0x00000000,
        (3 << 16) | 16, 2, 7,
        (4 << 16) | 5, 2, 0x6e69616d, 0x00000000,
        (2 << 16) | 19, 3,
        (3 << 16) | 33, 4, 3,
        (4 << 16) | 21, 5, 32, 0,
        (4 << 16) | 43, 5, 6, 0xFF00, // %6
        (4 << 16) | 43, 5, 7, 4,      // %7 (offset)
        (4 << 16) | 43, 5, 8, 8,      // %8 (count)
        (5 << 16) | 54, 3, 2, 0, 4,
        (2 << 16) | 248, 9,
        // %10 = OpBitFieldUExtract %5 %6 %7 %8 (203, wc=6)
        (6 << 16) | 203, 5, 10, 6, 7, 8,
        (1 << 16) | 253,
        (1 << 16) | 56,
    };
    const wgsl = try glslpp.spirvToWGSL(alloc, &words, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "extractBits(") != null);
}
