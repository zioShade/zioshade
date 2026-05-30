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

const OpDecorate: u32 = 71;
const OpMemberDecorate: u32 = 72;
const DecorationArrayStride: u32 = 6;
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

/// Return the first OpDecorate ... ArrayStride literal, or null. Assumes the
/// shader contains exactly one decorated array.
fn findFirstArrayStride(spv: []const u32) ?u32 {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OpDecorate and wc >= 4 and i + 3 < spv.len and spv[i + 2] == DecorationArrayStride) {
            return spv[i + 3];
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

// glslang-verified table for std430 row_major `buffer B { <mt> m; float t; }`.
// In row_major the stored vectors are rows: stride keys off the COLUMN count
// (rows span the columns). Exercises the col/row span swap in matrixMemberStride.
const row_major_cases = [_]Case{
    .{ .mt = "mat2x4", .layout = "std430", .stride = 8, .next_off = 32 }, // rows span 2 cols (vec2) -> 8; 4 rows * 8
    .{ .mt = "mat4x2", .layout = "std430", .stride = 16, .next_off = 32 }, // rows span 4 cols (vec4) -> 16; 2 rows * 16
    .{ .mt = "mat3", .layout = "std430", .stride = 16, .next_off = 48 }, // 3 rows * 16
    .{ .mt = "mat4", .layout = "std430", .stride = 16, .next_off = 64 }, // 4 rows * 16
};

test "std430 row_major matrix MatrixStride/size matches glslang (row span keys off columns)" {
    const alloc = std.testing.allocator;
    var any_fail = false;
    for (row_major_cases) |c| {
        const src = try std.fmt.allocPrintSentinel(alloc,
            \\#version 450
            \\layout(set=0,binding=0,{s},row_major) buffer B {{ {s} m; float t; }} x;
            \\layout(location=0) out vec4 o;
            \\void main() {{ o = vec4(x.m[0][0]*x.t); }}
        , .{ c.layout, c.mt }, 0);
        defer alloc.free(src);

        const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);

        const stride = findMemberMatrixStride(spv, 0);
        const next_off = findMemberOffset(spv, 1);
        if (stride == null or next_off == null or
            stride.? != c.stride or next_off.? != c.next_off)
        {
            std.debug.print(
                "FAIL row_major {s}: stride={?d} (want {d}), next_off={?d} (want {d})\n",
                .{ c.mt, stride, c.stride, next_off, c.next_off },
            );
            any_fail = true;
        }
    }
    try std.testing.expect(!any_fail);
}

const ArrayCase = struct {
    mt: []const u8,
    array_stride: u32,
    mat_stride: u32,
    /// offset of the trailing float (== array_stride * element_count == 2 * array_stride)
    next_off: u32,
};

// glslang-verified table for std430 `buffer B { <mt> m[2]; float t; }`.
// ArrayStride must stay consistent with the (now corrected) element matrix size.
const array_cases = [_]ArrayCase{
    .{ .mt = "mat4x2", .array_stride = 32, .mat_stride = 8, .next_off = 64 }, // 4 cols * 8 stride = 32 elem
    .{ .mt = "mat2", .array_stride = 16, .mat_stride = 8, .next_off = 32 }, // 2 cols * 8 = 16 elem
    .{ .mt = "mat4", .array_stride = 64, .mat_stride = 16, .next_off = 128 }, // 4 cols * 16 = 64 elem
};

test "std430 matrix-array ArrayStride stays consistent with element MatrixStride (matches glslang)" {
    const alloc = std.testing.allocator;
    var any_fail = false;
    for (array_cases) |c| {
        const src = try std.fmt.allocPrintSentinel(alloc,
            \\#version 450
            \\layout(set=0,binding=0,std430) buffer B {{ {s} m[2]; float t; }} x;
            \\layout(location=0) out vec4 o;
            \\void main() {{ o = vec4(x.m[0][0][0]*x.t); }}
        , .{c.mt}, 0);
        defer alloc.free(src);

        const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);

        const arr_stride = findFirstArrayStride(spv);
        const mat_stride = findMemberMatrixStride(spv, 0);
        const next_off = findMemberOffset(spv, 1);
        if (arr_stride == null or mat_stride == null or next_off == null or
            arr_stride.? != c.array_stride or mat_stride.? != c.mat_stride or next_off.? != c.next_off)
        {
            std.debug.print(
                "FAIL array {s}[2]: arrStride={?d} (want {d}), matStride={?d} (want {d}), next_off={?d} (want {d})\n",
                .{ c.mt, arr_stride, c.array_stride, mat_stride, c.mat_stride, next_off, c.next_off },
            );
            any_fail = true;
        }
    }
    try std.testing.expect(!any_fail);
}

const MslCase = struct { mt: []const u8, msl_type: []const u8 };

// The std430 MatrixStride this fix corrects is a direct input to MSL matrix-type
// selection (spirv_to_msl maps stride -> rows). Guard that coupling so a future
// change to matrixMemberStride can't silently corrupt MSL output.
const msl_cases = [_]MslCase{
    .{ .mt = "mat4", .msl_type = "float4x4" }, // pre-fix this was float4x2 (stride 8 bug)
    .{ .mt = "mat3x2", .msl_type = "float3x2" }, // 2-row -> stride 8, must not widen to float3x4
    .{ .mt = "mat2", .msl_type = "float2x2" },
};

test "std430 matrix maps to correct MSL matrix type (downstream of MatrixStride)" {
    const alloc = std.testing.allocator;
    var any_fail = false;
    for (msl_cases) |c| {
        const src = try std.fmt.allocPrintSentinel(alloc,
            \\#version 450
            \\layout(set=0,binding=0,std430) buffer B {{ {s} m; float t; }} x;
            \\layout(location=0) out vec4 o;
            \\void main() {{ o = vec4(x.m[0][0]*x.t); }}
        , .{c.mt}, 0);
        defer alloc.free(src);

        const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);
        const msl = try glslpp.spirvToMSL(alloc, spv, .{});
        defer alloc.free(msl);

        if (std.mem.indexOf(u8, msl, c.msl_type) == null) {
            std.debug.print("FAIL msl {s}: expected MSL type \"{s}\" not found\n", .{ c.mt, c.msl_type });
            any_fail = true;
        }
    }
    try std.testing.expect(!any_fail);
}
