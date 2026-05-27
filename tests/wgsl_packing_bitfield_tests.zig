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

test "M4.1 WGSL: packSnorm2x16 emits pack2x16snorm" {
    const alloc = std.testing.allocator;
    const wgsl = try compileWgsl(alloc,
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) flat out uint packed_uv;
        \\void main() { packed_uv = packSnorm2x16(uv); }
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
        \\void main() { packed_uv = packHalf2x16(uv); }
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
