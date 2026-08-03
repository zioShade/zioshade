// SPDX-License-Identifier: MIT
//! Corpus floor assertion for `common.minWordCount`.
//!
//! `minWordCount` is a rejection rule: any instruction shorter than its entry
//! is refused by every `parseModule`. An entry that is one word too LARGE is
//! therefore silently unsafe in the worst direction, it makes zioshade reject
//! spec-valid SPIR-V that it used to compile. A hand-written version of the
//! table had exactly that bug in five places (`OpTypeStruct` given 3 when a
//! zero-member struct is legal at 2, plus four ray-query and subgroup entries),
//! and none of the existing gates caught it: `zig build strict-gate` only
//! exercises the GLSL frontend, and no `parseModule` copy is reachable from
//! that path.
//!
//! This test is the check that actually protects the table. It walks every
//! `.spv` in the repository corpus and asserts, for every instruction of every
//! module, that the table's minimum is no larger than the real word count.
//! Reintroducing any over-strict entry fails it immediately and names the
//! offending file, opcode and counts.
//!
//! The deliberately truncated negative fixtures are excluded by name, since
//! being under the minimum is the whole point of those.

const std = @import("std");
const zioshade = @import("zioshade");
const compat = zioshade.compat;
const common = zioshade.spirv_cross_common;

const alloc = std.testing.allocator;

const SPIRV_MAGIC: u32 = 0x07230203;

/// Directories walked recursively for `.spv` files.
const corpus_dirs = [_][]const u8{ "tests", "src/testdata" };

/// Fixtures that are deliberately shorter than the spec minimum. They exist to
/// prove the check fires, so they must not be held to the floor.
fn isDeliberatelyTruncated(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.startsWith(u8, base, "truncated_");
}

const Counts = struct {
    modules: usize = 0,
    instructions: usize = 0,
};

fn checkModule(path: []const u8, bytes: []const u8, counts: *Counts) !void {
    if (bytes.len < 20 or bytes.len % 4 != 0) return;
    const word_len = bytes.len / 4;
    if (std.mem.readInt(u32, bytes[0..4], .little) != SPIRV_MAGIC) return;

    counts.modules += 1;

    var i: usize = 5;
    while (i < word_len) {
        const header = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        const word_count: usize = header >> 16;
        const opcode: u16 = @truncate(header & 0xFFFF);
        // A zero count or an overrun means the module itself is malformed, not
        // that the table is wrong. Stop scanning rather than fail.
        if (word_count == 0 or i + word_count > word_len) return;

        const op: zioshade.spirv.Op = @enumFromInt(opcode);
        if (common.minWordCount(op)) |min| {
            if (word_count < min) {
                std.debug.print(
                    "\nover-strict minWordCount: {s} opcode {d} has word_count {d} but the table demands {d}\n",
                    .{ path, opcode, word_count, min },
                );
                return error.MinWordCountAboveCorpusFloor;
            }
        }

        counts.instructions += 1;
        i += word_count;
    }
}

test "minWordCount never exceeds the real word count anywhere in the corpus" {
    var counts: Counts = .{};

    for (corpus_dirs) |dir_path| {
        const entries = try compat.walkDirAlloc(alloc, dir_path);
        defer compat.freeWalkEntries(alloc, entries);

        for (entries) |entry| {
            if (!entry.is_file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".spv")) continue;
            if (isDeliberatelyTruncated(entry.path)) continue;

            const bytes = compat.readFileByPath(alloc, entry.path, 64 * 1024 * 1024) catch continue;
            defer alloc.free(bytes);

            try checkModule(entry.path, bytes, &counts);
        }
    }

    // Guard against a vacuous pass: a walk that finds nothing would otherwise
    // report success. The corpus has well over a hundred modules.
    std.debug.print(
        "\ncorpus floor: {d} modules, {d} instructions checked\n",
        .{ counts.modules, counts.instructions },
    );
    try std.testing.expect(counts.modules >= 100);
    try std.testing.expect(counts.instructions >= 10_000);
}

test "the generated table matches the spec minima the reviewer verified by hand" {
    // Spot checks against instructions the hand-written table got wrong, so a
    // bad regeneration is caught even if the corpus happens not to contain the
    // opcode. Values are from spirv.core.grammar.json.
    const Case = struct { opcode: u16, min: u16 };
    const cases = [_]Case{
        .{ .opcode = 30, .min = 2 }, // OpTypeStruct, a zero-member struct is legal
        .{ .opcode = 4477, .min = 4 }, // OpRayQueryProceedKHR, emitted 4-word by src/codegen.zig
        .{ .opcode = 4479, .min = 5 }, // OpRayQueryGetIntersectionTypeKHR
        .{ .opcode = 5340, .min = 5 }, // OpRayQueryGetIntersectionTriangleVertexPositionsKHR
        .{ .opcode = 4432, .min = 5 }, // OpSubgroupReadInvocationKHR, NOT OpGroupNonUniformRotateKHR
        .{ .opcode = 4431, .min = 6 }, // OpGroupNonUniformRotateKHR
        .{ .opcode = 65, .min = 4 }, // OpAccessChain
        .{ .opcode = 79, .min = 5 }, // OpVectorShuffle
        .{ .opcode = 57, .min = 4 }, // OpFunctionCall
        .{ .opcode = 61, .min = 4 }, // OpLoad
        .{ .opcode = 62, .min = 3 }, // OpStore
    };
    for (cases) |c| {
        const op: zioshade.spirv.Op = @enumFromInt(c.opcode);
        try std.testing.expectEqual(@as(?u16, c.min), common.minWordCount(op));
    }
}
