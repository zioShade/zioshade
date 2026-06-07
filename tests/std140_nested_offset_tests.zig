// SPDX-License-Identifier: MIT OR Apache-2.0
// std140/std430 nested-struct member Offset regression (#181).
//
// Bug: a member that FOLLOWS a nested struct (or array-of-struct) in a UBO/SSBO
// block got the WRONG Offset. codegen's layout helpers looked the nested struct
// up only in `emitted_named_types`, but a struct reached through an interface
// (UBO/SSBO) block is cached in `emitted_interface_named_types`. The lookup
// missed and returned defaults (struct size 0 -> the next member did not
// advance and overlapped; struct alignment 16/8). This corrupted: the offset of
// any member after a nested struct, the offset after an array-of-struct, the
// ArrayStride of struct arrays, and the alignment after a small std430 struct.
//
// spirv-val does NOT catch these (the SPIR-V is well-formed, just wrong), so
// every expected value below is glslangValidator -V ground truth (Vulkan SDK
// 1.4.341.1). The fix is a dual-lookup fallback in codegen.zig matching the
// existing pattern at the nested-struct recursion sites.
const std = @import("std");
const glslpp = @import("glslpp");

const OpDecorate: u32 = 71;
const OpMemberDecorate: u32 = 72;
const DecorationBlock: u32 = 2;
const DecorationBufferBlock: u32 = 3;
const DecorationArrayStride: u32 = 6;
const DecorationOffset: u32 = 35;

/// Find the type id decorated `Block` or `BufferBlock` — the outer UBO/SSBO
/// block struct. Returns null if none.
fn findBlockTypeId(spv: []const u32) ?u32 {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OpDecorate and wc >= 3 and i + 2 < spv.len and
            (spv[i + 2] == DecorationBlock or spv[i + 2] == DecorationBufferBlock))
        {
            return spv[i + 1];
        }
        i += wc;
    }
    return null;
}

/// Offset literal for `member_index` of struct `struct_id`. Scoped to the
/// specific struct so an inner struct's member 1 cannot shadow the block's.
fn findMemberOffsetOf(spv: []const u32, struct_id: u32, member_index: u32) ?u32 {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OpMemberDecorate and wc >= 5 and i + 4 < spv.len and
            spv[i + 1] == struct_id and
            spv[i + 2] == member_index and spv[i + 3] == DecorationOffset)
        {
            return spv[i + 4];
        }
        i += wc;
    }
    return null;
}

/// First ArrayStride literal anywhere in the module. Used by cases with exactly
/// one decorated array.
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
    name: []const u8,
    src: []const u8,
    /// (member_index_in_block, expected_offset) pairs for the Block struct.
    offsets: []const [2]u32,
    /// expected first ArrayStride, or null to skip.
    array_stride: ?u32 = null,
};

// Every expected value VERIFIED with `glslangValidator -V` + `spirv-dis`.
const cases = [_]Case{
    // std140 UBO: mvp follows nested Material{vec4 albedo; Light l;}. Material
    // size = 48 (albedo@0, Light@16 size 32). mvp Offset 48.
    .{
        .name = "std140 mvp after nested struct -> 48",
        .src =
        \\#version 450
        \\struct Light { vec4 pos; float intensity; };
        \\struct Material { vec4 albedo; Light l; };
        \\layout(set=0,binding=0,std140) uniform Scene { Material mat; mat4 mvp; } s;
        \\layout(location=0) out vec4 o;
        \\void main() { o = s.mat.albedo * s.mat.l.intensity * s.mvp[0]; }
        ,
        .offsets = &.{ .{ 0, 0 }, .{ 1, 48 } },
    },
    // std430 SSBO, same shape -> mvp Offset 48.
    .{
        .name = "std430 mvp after nested struct -> 48",
        .src =
        \\#version 450
        \\struct Light { vec4 pos; float intensity; };
        \\struct Material { vec4 albedo; Light l; };
        \\layout(set=0,binding=0,std430) buffer Scene { Material mat; mat4 mvp; } s;
        \\layout(location=0) out vec4 o;
        \\void main() { o = s.mat.albedo * s.mat.l.intensity * s.mvp[0]; }
        ,
        .offsets = &.{ .{ 0, 0 }, .{ 1, 48 } },
    },
    // struct-after-struct: a@0, b@48, tail@96.
    .{
        .name = "std140 struct after struct -> b 48, tail 96",
        .src =
        \\#version 450
        \\struct Light { vec4 pos; float intensity; };
        \\struct Material { vec4 albedo; Light l; };
        \\layout(set=0,binding=0,std140) uniform B { Material a; Material b; float tail; } x;
        \\layout(location=0) out vec4 o;
        \\void main() { o = x.a.albedo + x.b.albedo + vec4(x.tail); }
        ,
        .offsets = &.{ .{ 0, 0 }, .{ 1, 48 }, .{ 2, 96 } },
    },
    // array-of-struct: Light lights[3] (ArrayStride 32), vec4 tail@96.
    .{
        .name = "std140 array-of-struct -> stride 32, tail 96",
        .src =
        \\#version 450
        \\struct Light { vec4 pos; float intensity; };
        \\layout(set=0,binding=0,std140) uniform B { Light lights[3]; vec4 tail; } x;
        \\layout(location=0) out vec4 o;
        \\void main() { o = x.lights[0].pos + x.tail; }
        ,
        .offsets = &.{ .{ 0, 0 }, .{ 1, 96 } },
        .array_stride = 32,
    },
    // small std430 struct: Small{float a} size 4 -> t Offset 4 (alignment after
    // a small std430 struct must NOT be the default 16).
    .{
        .name = "std430 small struct -> t 4",
        .src =
        \\#version 450
        \\struct Small { float a; };
        \\layout(set=0,binding=0,std430) buffer B { Small s; float t; } x;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(x.s.a + x.t); }
        ,
        .offsets = &.{ .{ 0, 0 }, .{ 1, 4 } },
    },
    // mat4 mvp; Light light; float intensity -> light@64, intensity@96.
    .{
        .name = "std140 mat4, struct, float -> intensity 96",
        .src =
        \\#version 450
        \\struct Light { vec4 pos; float intensity; };
        \\layout(set=0,binding=0,std140) uniform B { mat4 mvp; Light light; float intensity; } x;
        \\layout(location=0) out vec4 o;
        \\void main() { o = x.mvp[0] + x.light.pos + vec4(x.intensity); }
        ,
        .offsets = &.{ .{ 0, 0 }, .{ 1, 64 }, .{ 2, 96 } },
    },
    // std140 STRUCT base alignment rounds UP to 16: S{float a} has max-member
    // alignment 4, but a struct's std140 base alignment is roundUp(4,16)=16, and
    // its size likewise rounds to 16, so a FLOAT `tail` (align 4) follows at
    // Offset 16 — NOT 4. A vec4 tail would mask this (its own 16-alignment pulls
    // it up regardless), so we use a float tail to isolate the struct base-align
    // rule. glslang oracle = 16. (Pre-fix glslpp gave 4.)
    .{
        .name = "std140 scalar-only struct base-align -> float tail 16",
        .src =
        \\#version 450
        \\struct S { float a; };
        \\layout(set=0,binding=0,std140) uniform U { S s; float tail; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.s.a + u.tail); }
        ,
        .offsets = &.{ .{ 0, 0 }, .{ 1, 16 } },
    },
    // std140 STRUCT base alignment rounds UP to 16: V2{vec2 a} has max-member
    // alignment 8, but roundUp(8,16)=16, so a FLOAT `tail` follows at Offset 16
    // — NOT 8. glslang oracle = 16. (Pre-fix glslpp gave 8.)
    .{
        .name = "std140 vec2-only struct base-align -> float tail 16",
        .src =
        \\#version 450
        \\struct V2 { vec2 a; };
        \\layout(set=0,binding=0,std140) uniform U { V2 s; float tail; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.s.a, 0, u.tail); }
        ,
        .offsets = &.{ .{ 0, 0 }, .{ 1, 16 } },
    },
    // std430 must NOT round struct base alignment to 16: S{float a} keeps its
    // REAL max-member alignment 4, so `t` (a float) follows at Offset 4.
    // glslang oracle = 4. This proves FIX 1 is std140-only and stays correct
    // throughout.
    .{
        .name = "std430 scalar struct base-align stays 4 -> t 4",
        .src =
        \\#version 450
        \\struct S { float a; };
        \\layout(set=0,binding=0,std430) buffer B { S s; float t; } b;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(b.s.a + b.t); }
        ,
        .offsets = &.{ .{ 0, 0 }, .{ 1, 4 } },
    },
};

test "std140/std430 member offset after a nested struct matches glslang (#181)" {
    const alloc = std.testing.allocator;
    var any_fail = false;
    for (cases) |c| {
        const src = try alloc.dupeZ(u8, c.src);
        defer alloc.free(src);

        const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);

        const block_id = findBlockTypeId(spv) orelse {
            std.debug.print("FAIL {s}: no Block-decorated struct found\n", .{c.name});
            any_fail = true;
            continue;
        };

        for (c.offsets) |pair| {
            const got = findMemberOffsetOf(spv, block_id, pair[0]);
            if (got == null or got.? != pair[1]) {
                std.debug.print(
                    "FAIL {s}: block member {d} Offset={?d} (want {d})\n",
                    .{ c.name, pair[0], got, pair[1] },
                );
                any_fail = true;
            }
        }

        if (c.array_stride) |want| {
            const got = findFirstArrayStride(spv);
            if (got == null or got.? != want) {
                std.debug.print(
                    "FAIL {s}: ArrayStride={?d} (want {d})\n",
                    .{ c.name, got, want },
                );
                any_fail = true;
            }
        }
    }
    try std.testing.expect(!any_fail);
}
