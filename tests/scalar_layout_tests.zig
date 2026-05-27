// SPDX-License-Identifier: MIT OR Apache-2.0
// M8.1: GL_EXT_scalar_block_layout — scalar packing rules.
//
// The extension changes the default layout for UBO/SSBO blocks from std140
// (vec3-padded-to-vec4, 16-byte array stride) to scalar (every type aligned to
// its scalar component, tight packing).
const std = @import("std");
const glslpp = @import("glslpp");

/// Walk SPIR-V words and return the Offset literal for the given member of
/// the first OpMemberDecorate ... Offset instruction matching member_index.
fn findMemberOffset(spv: []const u32, member_index: u32) ?u32 {
    var i: usize = 5; // skip 5-word header
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        // OpMemberDecorate = 72; decoration enum Offset = 35
        if (op == 72 and wc >= 5 and i + 4 < spv.len and spv[i + 2] == member_index and spv[i + 3] == 35) {
            return spv[i + 4];
        }
        i += wc;
    }
    return null;
}

/// Walk SPIR-V words and return the literal of the *first* OpDecorate ...
/// ArrayStride instruction. Assumes the test shader contains exactly one
/// runtime array — do not use on multi-array modules.
fn findFirstArrayStride(spv: []const u32) ?u32 {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        // OpDecorate = 71; decoration enum ArrayStride = 6
        if (op == 71 and wc >= 4 and i + 3 < spv.len and spv[i + 2] == 6) {
            return spv[i + 3];
        }
        i += wc;
    }
    return null;
}

test "scalar layout: float+vec3 packs vec3 at offset 4 with GL_EXT_scalar_block_layout" {
    // float a (offset 0, size 4) then vec3 b:
    //   scalar: vec3 has alignment 4 (scalar component), so b at offset 4.
    //   std140: vec3 has alignment 16, so b at offset 16.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_scalar_block_layout : require
        \\layout(set=0, binding=0) uniform Block { float a; vec3 b; } u;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(u.b, u.a); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const offset_b = findMemberOffset(spv, 1) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u32, 4), offset_b);
    // Negative guard: must NOT pad to the std140 vec3-aligned-to-16 offset.
    try std.testing.expect(offset_b != 16);
}

test "scalar layout: float+vec3 pads to offset 16 without extension (std140 default)" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(set=0, binding=0) uniform Block { float a; vec3 b; } u;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(u.b, u.a); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const offset_b = findMemberOffset(spv, 1) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u32, 16), offset_b);
}

test "scalar layout: vec3 runtime array gets ArrayStride 12" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_scalar_block_layout : require
        \\layout(set=0, binding=0) buffer Buf { vec3 data[]; } b;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(b.data[0], 1.0); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const stride = findFirstArrayStride(spv) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u32, 12), stride);
}
