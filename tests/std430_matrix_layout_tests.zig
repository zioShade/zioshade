// SPDX-License-Identifier: MIT OR Apache-2.0
// std430/std140 matrix layout: MatrixStride must be consistent with the member
// offsets the layout reserves, and must match glslangValidator -V.
//
// Regression for: glslpp emitted an INCONSISTENT MatrixStride for matrices in
// std430 storage buffers (e.g. mat4 -> MatrixStride 8 while reserving 64 bytes,
// i.e. a 16-byte column stride). The reserved size (offset of the next member)
// and the declared column stride must agree: stride * columns == reserved size.
//
// Every expected value below was VERIFIED against `glslangValidator -V` (Vulkan
// SDK 1.4.341.1) — glslang is the oracle. See the per-row comments.
const std = @import("std");
const glslpp = @import("glslpp");

const OpMemberDecorate: u32 = 72;
const DecorationMatrixStride: u32 = 7;
const DecorationOffset: u32 = 35;

/// Return the MatrixStride literal for `member_index`, or null if absent.
fn findMemberMatrixStride(spv: []const u32, member_index: u32) ?u32 {
    var i: usize = 5; // skip 5-word header
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OpMemberDecorate and wc >= 5 and i + 4 < spv.len and
            spv[i + 2] == member_index and spv[i + 3] == DecorationMatrixStride)
        {
            return spv[i + 4];
        }
        i += wc;
    }
    return null;
}

/// Return the Offset literal for `member_index`, or null if absent.
fn findMemberOffset(spv: []const u32, member_index: u32) ?u32 {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OpMemberDecorate and wc >= 5 and i + 4 < spv.len and
            spv[i + 2] == member_index and spv[i + 3] == DecorationOffset)
        {
            return spv[i + 4];
        }
        i += wc;
    }
    return null;
}

const Case = struct {
    mt: []const u8,
    layout: []const u8,
    /// MatrixStride glslang emits for member 0.
    stride: u32,
    /// Offset glslang reserves for member 1 (the float after the matrix) ==
    /// the matrix's reserved size. Must equal stride * column_count.
    next_off: u32,
};

// glslang-verified table for `buffer B { <mt> m; float t; }`.
const cases = [_]Case{
    // ── std140: columns are always vec4-aligned -> stride 16 everywhere ──
    .{ .mt = "mat2", .layout = "std140", .stride = 16, .next_off = 32 },
    .{ .mt = "mat3", .layout = "std140", .stride = 16, .next_off = 48 },
    .{ .mt = "mat4", .layout = "std140", .stride = 16, .next_off = 64 },
    .{ .mt = "mat2x3", .layout = "std140", .stride = 16, .next_off = 32 },
    .{ .mt = "mat3x2", .layout = "std140", .stride = 16, .next_off = 48 },
    .{ .mt = "mat2x4", .layout = "std140", .stride = 16, .next_off = 32 },
    .{ .mt = "mat4x2", .layout = "std140", .stride = 16, .next_off = 64 },
    .{ .mt = "mat3x4", .layout = "std140", .stride = 16, .next_off = 48 },
    .{ .mt = "mat4x3", .layout = "std140", .stride = 16, .next_off = 64 },
    // ── std430: column stride = 8 for 2-row columns (vec2), 16 for vec3/vec4 ──
    .{ .mt = "mat2", .layout = "std430", .stride = 8, .next_off = 16 }, // 2 cols * 8
    .{ .mt = "mat3", .layout = "std430", .stride = 16, .next_off = 48 }, // 3 cols * 16
    .{ .mt = "mat4", .layout = "std430", .stride = 16, .next_off = 64 }, // 4 cols * 16 (reported bug)
    .{ .mt = "mat2x3", .layout = "std430", .stride = 16, .next_off = 32 }, // 2 cols * 16
    .{ .mt = "mat3x2", .layout = "std430", .stride = 8, .next_off = 24 }, // 3 cols * 8
    .{ .mt = "mat2x4", .layout = "std430", .stride = 16, .next_off = 32 }, // 2 cols * 16
    .{ .mt = "mat4x2", .layout = "std430", .stride = 8, .next_off = 32 }, // 4 cols * 8
    .{ .mt = "mat3x4", .layout = "std430", .stride = 16, .next_off = 48 }, // 3 cols * 16
    .{ .mt = "mat4x3", .layout = "std430", .stride = 16, .next_off = 64 }, // 4 cols * 16
};

test "std430/std140 matrix MatrixStride matches glslang and is consistent with reserved size" {
    const alloc = std.testing.allocator;
    var any_fail = false;
    for (cases) |c| {
        const src = try std.fmt.allocPrintSentinel(alloc,
            \\#version 450
            \\layout(set=0,binding=0,{s}) buffer B {{ {s} m; float t; }} x;
            \\layout(location=0) out vec4 o;
            \\void main() {{ o = vec4(x.m[0][0]*x.t); }}
        , .{ c.layout, c.mt }, 0);
        defer alloc.free(src);

        const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);

        const stride = findMemberMatrixStride(spv, 0);
        const next_off = findMemberOffset(spv, 1);
        if (stride == null or next_off == null) {
            std.debug.print("FAIL {s} {s}: missing stride/offset decoration\n", .{ c.layout, c.mt });
            any_fail = true;
            continue;
        }
        if (stride.? != c.stride or next_off.? != c.next_off) {
            std.debug.print(
                "FAIL {s} {s}: stride={d} (want {d}), next_off={d} (want {d})\n",
                .{ c.layout, c.mt, stride.?, c.stride, next_off.?, c.next_off },
            );
            any_fail = true;
        }
    }
    try std.testing.expect(!any_fail);
}

const AlignCase = struct {
    mt: []const u8,
    /// matrix start offset after a leading `float a` (its std430 alignment)
    mat_off: u32,
    /// offset of the trailing `float t` (matrix reserved size from mat_off)
    next_off: u32,
};

// glslang-verified table for std430 `buffer B { float a; <mt> m; float t; }`.
// 2-row matrices align to 8 (vec2), not 16.
const align_cases = [_]AlignCase{
    .{ .mt = "mat2", .mat_off = 8, .next_off = 24 }, // align 8, size 16
    .{ .mt = "mat4x2", .mat_off = 8, .next_off = 40 }, // align 8, size 32
    .{ .mt = "mat4", .mat_off = 16, .next_off = 80 }, // align 16, size 64
};

test "std430 matrix member alignment matches glslang (2-row matrices align to 8)" {
    const alloc = std.testing.allocator;
    var any_fail = false;
    for (align_cases) |c| {
        const src = try std.fmt.allocPrintSentinel(alloc,
            \\#version 450
            \\layout(set=0,binding=0,std430) buffer B {{ float a; {s} m; float t; }} x;
            \\layout(location=0) out vec4 o;
            \\void main() {{ o = vec4(x.m[0][0]*x.t + x.a); }}
        , .{c.mt}, 0);
        defer alloc.free(src);

        const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);

        const mat_off = findMemberOffset(spv, 1);
        const next_off = findMemberOffset(spv, 2);
        if (mat_off == null or next_off == null) {
            std.debug.print("FAIL std430 {s}: missing offset decoration\n", .{c.mt});
            any_fail = true;
            continue;
        }
        if (mat_off.? != c.mat_off or next_off.? != c.next_off) {
            std.debug.print(
                "FAIL std430 {s}: mat_off={d} (want {d}), next_off={d} (want {d})\n",
                .{ c.mt, mat_off.?, c.mat_off, next_off.?, c.next_off },
            );
            any_fail = true;
        }
    }
    try std.testing.expect(!any_fail);
}
