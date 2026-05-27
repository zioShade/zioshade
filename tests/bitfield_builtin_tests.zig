// SPDX-License-Identifier: MIT OR Apache-2.0
//! GLSL 400+ bitfield built-ins: bitfieldInsert / bitfieldExtract.
//!
//! Verifies that the semantic analyzer accepts these as real GLSL built-ins
//! and emits the correct core SPIR-V opcodes:
//!   bitfieldInsert(base, insert, offset, count)  → OpBitFieldInsert     (201)
//!   bitfieldExtract(int_value, offset, count)    → OpBitFieldSExtract  (202)
//!   bitfieldExtract(uint_value, offset, count)   → OpBitFieldUExtract  (203)
//! Vector forms (ivecN/uvecN) are preserved natively by SPIR-V.

const std = @import("std");
const glslpp = @import("glslpp");

fn findOpcode(spv: []const u32, opcode: u16) bool {
    if (spv.len < 5) return false;
    var i: usize = 5;
    while (i < spv.len) {
        const wc: u32 = spv[i] >> 16;
        const op: u32 = spv[i] & 0xFFFF;
        if (op == @as(u32, opcode)) return true;
        if (wc == 0) return false; // malformed — avoid infinite loop
        i += wc;
    }
    return false;
}

test "bitfieldExtract (uint) compiles and emits OpBitFieldUExtract" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(set=0, binding=0) uniform Block { uint v; int o; int c; } b;
        \\layout(location=0) out uint result;
        \\void main() { result = bitfieldExtract(b.v, b.o, b.c); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(findOpcode(spv, 203)); // OpBitFieldUExtract
}

test "bitfieldExtract (int) emits OpBitFieldSExtract" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(set=0, binding=0) uniform Block { int v; int o; int c; } b;
        \\layout(location=0) out int result;
        \\void main() { result = bitfieldExtract(b.v, b.o, b.c); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(findOpcode(spv, 202)); // OpBitFieldSExtract
}

test "bitfieldInsert emits OpBitFieldInsert" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(set=0, binding=0) uniform Block { uint base; uint ins; int o; int c; } b;
        \\layout(location=0) out uint result;
        \\void main() { result = bitfieldInsert(b.base, b.ins, b.o, b.c); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(findOpcode(spv, 201)); // OpBitFieldInsert
}

test "bitfieldExtract (uvec2) vector form emits OpBitFieldUExtract" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(set=0, binding=0) uniform Block { uvec2 v; int o; int c; } b;
        \\layout(location=0) out uvec2 result;
        \\void main() { result = bitfieldExtract(b.v, b.o, b.c); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(findOpcode(spv, 203)); // OpBitFieldUExtract on vector
}

test "bitfieldInsert (ivec4) vector form emits OpBitFieldInsert" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(set=0, binding=0) uniform Block { ivec4 base; ivec4 ins; int o; int c; } b;
        \\layout(location=0) out ivec4 result;
        \\void main() { result = bitfieldInsert(b.base, b.ins, b.o, b.c); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(findOpcode(spv, 201)); // OpBitFieldInsert on vector
}
