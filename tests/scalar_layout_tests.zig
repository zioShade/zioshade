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

/// True if the SPIR-V stream contains ANY OpMemberDecorate (opcode 72) whose
/// decoration literal (word 3) equals `decoration`. Not scoped to a specific
/// struct or member — a single match anywhere in the module counts, which is
/// sufficient here: a RowMajor *and* a ColMajor both appearing proves the two
/// blocks were emitted as distinct structs rather than merged onto one.
fn hasMemberDecoration(spv: []const u32, decoration: u32) bool {
    var i: usize = 5; // skip 5-word header
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        // OpMemberDecorate = 72: word1=struct id, word2=member index, word3=decoration
        if (op == 72 and wc >= 4 and i + 3 < spv.len and spv[i + 3] == decoration) return true;
        i += wc;
    }
    return false;
}

/// True if the SPIR-V stream contains ANY OpDecorate (opcode 71) whose
/// decoration literal (word 2) equals `decoration`, ignoring any extra operand.
/// Used for value-less decorations such as Block (2) / BufferBlock (3).
fn hasDecoration(spv: []const u32, decoration: u32) bool {
    var i: usize = 5; // skip 5-word header
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        // OpDecorate = 71: word1=target id, word2=decoration[, word3=operand]
        if (op == 71 and wc >= 3 and i + 2 < spv.len and spv[i + 2] == decoration) return true;
        i += wc;
    }
    return false;
}

/// True if the SPIR-V stream contains an OpDecorate (opcode 71) with the given
/// `decoration` literal (word 2) AND a matching single `value` operand (word 3).
/// Used to assert a specific decoration value is present, e.g. ArrayStride (6)
/// equal to 16 or 4. Unlike findFirstArrayStride, this scans EVERY OpDecorate,
/// so it is safe on modules with more than one array type.
fn hasDecorationValue(spv: []const u32, decoration: u32, value: u32) bool {
    var i: usize = 5; // skip 5-word header
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == 71 and wc >= 4 and i + 3 < spv.len and spv[i + 2] == decoration and spv[i + 3] == value) return true;
        i += wc;
    }
    return false;
}

/// Count OpTypeStruct (opcode 30) instructions in the SPIR-V stream.
fn countStructTypes(spv: []const u32) usize {
    var count: usize = 0;
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == 30) count += 1; // OpTypeStruct = 30
        i += wc;
    }
    return count;
}

// Regression: two interface blocks with byte-identical member TYPES and NAMES
// but DIFFERENT layout qualifiers (row_major vs column_major) must NOT be merged
// by the struct-dedup cache. The dedup key used to be computed before the block
// layout was resolved, so block B silently inherited block A's RowMajor
// decoration — the module ended up with a single struct and no ColMajor at all,
// i.e. block b was wrongly treated as row-major. The oracle (spirv-cross/
// glslang) keeps A and B as distinct structs decorated RowMajor vs ColMajor.
// This bug is masked in the MSL/HLSL text backends (their row-major matrix
// access is not yet differentiated), so it can only be caught at the SPIR-V
// level. RowMajor = decoration 4, ColMajor = decoration 5 (SPIR-V spec).
test "block dedup keeps row_major and column_major UBO blocks as distinct structs" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(binding=0,std140,row_major)    uniform A { mat4 m; } a;
        \\layout(binding=1,std140,column_major) uniform B { mat4 m; } b;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[0] + b.m[0]; }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);

    // RowMajor (4) comes from block A, ColMajor (5) from block B. If the blocks
    // were merged, only the first block's RowMajor survives and ColMajor is gone.
    try std.testing.expect(hasMemberDecoration(spv, 4)); // RowMajor
    try std.testing.expect(hasMemberDecoration(spv, 5)); // ColMajor

    // Structurally the two blocks are distinct struct types, not one merged type.
    try std.testing.expectEqual(@as(usize, 2), countStructTypes(spv));
}

// Negative / no-regression guard for the fix above: tightening the dedup key must
// NOT over-separate. Two blocks that are byte-identical in members, names AND
// layout (both std140, both default column-major) must still MERGE onto a single
// struct — otherwise the fix would bloat every module with duplicate types.
test "block dedup still merges two UBO blocks identical in members and layout" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(binding=0,std140) uniform A { mat4 m; } a;
        \\layout(binding=1,std140) uniform B { mat4 m; } b;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[0] + b.m[0]; }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);

    // Identical column-major std140 blocks → exactly one shared struct type.
    try std.testing.expectEqual(@as(usize, 1), countStructTypes(spv));
}

// GAP 1: two interface blocks with byte-identical array members but DIFFERENT
// layout qualifiers (std140 vs std430) need DIFFERENT array strides — std140
// rounds the float[2] element stride up to 16, std430 packs it at 4. The array
// TYPE was deduped on (element, length) ALONE — both in codegen's
// emitted_array_types cache and in the dedupArrayTypes post-pass — so the two
// blocks shared a single array type carrying a single ArrayStride (16); the
// std430 stride (4) was silently dropped. Worse, sharing the array made the two
// OpTypeStruct byte-identical, so dedupStructTypes then collapsed A and B onto
// one struct (one id with both names). The oracle (glslangValidator -V) emits
// two array types decorated ArrayStride 16 and ArrayStride 4 respectively.
// ArrayStride = decoration 6 (SPIR-V spec).
test "block dedup: std140 and std430 array members keep distinct ArrayStride 16 and 4" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(binding=0,std140) uniform A { float arr[2]; } a;
        \\layout(binding=1,std430) buffer  B { float arr[2]; } b;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(a.arr[0], a.arr[1], b.arr[0], b.arr[1]); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);

    // The std140 element stride (16) AND the std430 element stride (4) must both
    // be present — proof the two layouts produced two distinct array types.
    try std.testing.expect(hasDecorationValue(spv, 6, 16)); // ArrayStride 16
    try std.testing.expect(hasDecorationValue(spv, 6, 4)); // ArrayStride 4
    // Distinct array members ⇒ the two blocks are distinct struct types, not one
    // merged type sharing a single stride.
    try std.testing.expectEqual(@as(usize, 2), countStructTypes(spv));
}

// GAP 2: a plain (non-block) struct and a uniform BLOCK with byte-identical
// member types AND names must NOT be merged by the struct-dedup cache. The dedup
// key folded member types/names + block layout but NOT the needs_block flag, so
// the plain struct (emitted first, with no Block/Offset decorations) and the UBO
// block collapsed onto one id — leaving the `uniform` variable pointing at a
// struct with no Block decoration. That is invalid for Vulkan
// (VUID-StandaloneSpirv-Uniform-06676: a Uniform variable's type must be Block-
// or BufferBlock-decorated). The oracle keeps the two structs distinct and emits
// Block + Offset 0/4 on the block. Block = decoration 2, member Offset = 35.
// (countStructTypes is NOT asserted here: the local `s` is scalarized away, so
//  the plain struct S is legitimately DCE'd once it no longer aliases the block.)
test "block dedup: plain struct and identical UBO block stay distinct (needs_block)" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\struct S { float x; float y; };
        \\layout(binding=0,std140) uniform B { float x; float y; } bb;
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\  S s;
        \\  s.x = bb.x;
        \\  s.y = bb.y;
        \\  o = vec4(s.x, s.y, 0.0, 0.0);
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);

    // The uniform block must carry a Block decoration; the wrong merge dropped it.
    try std.testing.expect(hasDecoration(spv, 2)); // Block
    // …and its member layout (Offset 4 on the second float) must be present.
    try std.testing.expectEqual(@as(u32, 4), findMemberOffset(spv, 1) orelse 0xFFFF_FFFF);
}
