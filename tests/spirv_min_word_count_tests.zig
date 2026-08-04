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
//! The deliberately malformed fixtures are excluded by name, since being under
//! the minimum (or not being a well-formed module at all) is the whole point of
//! those. Everything else in the corpus is required to parse: an unreadable
//! file, a non-module `.spv`, or a malformed instruction stream fails the test
//! rather than being skipped. A corpus test that quietly skips is the same class
//! of defect this table exists to prevent.

const std = @import("std");
const zioshade = @import("zioshade");
const compat = zioshade.compat;
const common = zioshade.spirv_cross_common;

const alloc = std.testing.allocator;

const SPIRV_MAGIC: u32 = 0x07230203;

/// Directories walked recursively for `.spv` files.
const corpus_dirs = [_][]const u8{ "tests", "src/testdata" };

/// Fixtures that are deliberately malformed. They exist to prove the parser
/// rejects bad input, so they must not be held to the floor. Anything not named
/// here is required to be a well-formed module.
fn isDeliberatelyMalformed(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    // Instructions truncated below their opcode minimum: the negative fixtures
    // for the very check this test guards.
    if (std.mem.startsWith(u8, base, "truncated_")) return true;
    // A valid SPIR-V header followed by garbage words (honest-error fixture).
    if (std.mem.eql(u8, base, "hostile_garbage.spv")) return true;
    return false;
}

const Counts = struct {
    modules: usize = 0,
    instructions: usize = 0,
};

fn checkModule(path: []const u8, bytes: []const u8, counts: *Counts) !void {
    if (bytes.len < 20 or bytes.len % 4 != 0) {
        std.debug.print(
            "\nnot a SPIR-V module: {s} is {d} bytes (need >= 20 and a multiple of 4)\n",
            .{ path, bytes.len },
        );
        return error.CorpusFileIsNotAModule;
    }
    const word_len = bytes.len / 4;
    if (std.mem.readInt(u32, bytes[0..4], .little) != SPIRV_MAGIC) {
        std.debug.print("\nnot a SPIR-V module: {s} has the wrong magic word\n", .{path});
        return error.CorpusFileIsNotAModule;
    }

    counts.modules += 1;

    var i: usize = 5;
    while (i < word_len) {
        const header = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        const word_count: usize = header >> 16;
        const opcode: u16 = @truncate(header & 0xFFFF);
        // A zero count or an overrun means the module itself is malformed. Every
        // corpus module that is not named in isDeliberatelyMalformed is supposed
        // to be well formed, so this is a failure and not a reason to abandon
        // the rest of the scan silently.
        if (word_count == 0) {
            std.debug.print(
                "\nmalformed corpus module: {s} has a zero word count at word {d}\n",
                .{ path, i },
            );
            return error.CorpusModuleMalformed;
        }
        if (i + word_count > word_len) {
            std.debug.print(
                "\nmalformed corpus module: {s} instruction at word {d} claims {d} words, past the {d}-word end\n",
                .{ path, i, word_count, word_len },
            );
            return error.CorpusModuleMalformed;
        }

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
            if (isDeliberatelyMalformed(entry.path)) continue;

            const bytes = compat.readFileByPath(alloc, entry.path, 64 * 1024 * 1024) catch |err| {
                std.debug.print(
                    "\nunreadable corpus module: {s} ({s})\n",
                    .{ entry.path, @errorName(err) },
                );
                return err;
            };
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
