//! Self-tests for the conformance runner's exit decision and command line.
//!
//! The strict gate is the project's headline verification artifact, so the
//! runner must never exit 0 for a run that did not actually verify anything.
//! These tests pin the four ways that used to look green: an empty run, an
//! infrastructure failure, a pass count under the pinned floor, and a floor
//! flag that was mistyped and silently swallowed by the argument parser.

const std = @import("std");
const runner = @import("runner.zig");
const zioshade = @import("zioshade");

const Stats = runner.Stats;
const shouldFail = runner.shouldFail;
const parseArgs = runner.parseArgs;
const ArgDiag = runner.ArgDiag;

test "a fully green run with no floor exits zero" {
    const stats = Stats{ .pass = 2108, .xfail = 13 };
    try std.testing.expect(!shouldFail(stats, null));
}

test "an empty run fails even though nothing reported a failure" {
    const stats = Stats{};
    try std.testing.expectEqual(@as(u32, 0), stats.total());
    try std.testing.expect(shouldFail(stats, null));
}

test "an infra error fails even when fail and compile_error are zero" {
    const stats = Stats{ .pass = 2108, .infra_error = 1 };
    try std.testing.expectEqual(@as(u32, 0), stats.fail);
    try std.testing.expectEqual(@as(u32, 0), stats.compile_error);
    try std.testing.expect(shouldFail(stats, null));
}

test "a pass count under the floor fails" {
    const stats = Stats{ .pass = 2107, .xfail = 13 };
    try std.testing.expect(shouldFail(stats, 2108));
    try std.testing.expect(!shouldFail(stats, 2107));
    // Without a floor the same run is accepted, so the floor is what catches
    // a silently shrinking corpus.
    try std.testing.expect(!shouldFail(stats, null));
}

test "a skipped-everything run fails once a floor is pinned" {
    const stats = Stats{ .skip = 2108 };
    try std.testing.expect(!shouldFail(stats, null));
    try std.testing.expect(shouldFail(stats, 1));
}

test "total counts infra errors" {
    const stats = Stats{ .pass = 1, .fail = 1, .skip = 1, .compile_error = 1, .infra_error = 1, .xfail = 1 };
    try std.testing.expectEqual(@as(u32, 6), stats.total());
}

// ── command line ────────────────────────────────────────────────────
// argv[0] is the program name, so every case below starts with a dummy.

fn parse(argv: []const []const u8) !runner.Options {
    var diag = ArgDiag{};
    return parseArgs(argv, &diag);
}

test "the floor is accepted in both = and space form" {
    const joined = try parse(&.{ "runner", "--strict-gate", "--min-pass=2108" });
    try std.testing.expectEqual(@as(?u32, 2108), joined.min_pass);
    try std.testing.expect(joined.strict_gate);

    const separated = try parse(&.{ "runner", "--strict-gate", "--min-pass", "2108" });
    try std.testing.expectEqual(@as(?u32, 2108), separated.min_pass);
    try std.testing.expect(separated.strict_gate);
}

test "a mistyped floor flag is rejected, not swallowed as a target" {
    var diag = ArgDiag{};
    try std.testing.expectError(
        error.UnknownOption,
        parseArgs(&.{ "runner", "--strict-gate", "--minpass=2108" }, &diag),
    );
    try std.testing.expectEqualStrings("--minpass=2108", diag.arg);
}

test "any unrecognised option beginning with a dash is rejected" {
    var diag = ArgDiag{};
    try std.testing.expectError(
        error.UnknownOption,
        parseArgs(&.{ "runner", "--summary" }, &diag),
    );
    try std.testing.expectError(
        error.UnknownOption,
        parseArgs(&.{ "runner", "-m", "2108" }, &diag),
    );
}

test "a floor with a missing or non-numeric value is rejected" {
    var diag = ArgDiag{};
    try std.testing.expectError(
        error.MissingValue,
        parseArgs(&.{ "runner", "--strict-gate", "--min-pass" }, &diag),
    );
    try std.testing.expectError(
        error.MissingValue,
        parseArgs(&.{ "runner", "--strict-gate", "--min-pass=" }, &diag),
    );
    try std.testing.expectError(
        error.InvalidNumber,
        parseArgs(&.{ "runner", "--strict-gate", "--min-pass=lots" }, &diag),
    );
    try std.testing.expectError(
        error.InvalidNumber,
        parseArgs(&.{ "runner", "--strict-gate", "--min-pass=-1" }, &diag),
    );
}

test "an argument the gate modes would ignore is rejected" {
    var diag = ArgDiag{};
    // strict-gate walks every suite, so a positional target cannot be honored.
    // Accepting it silently is how a typo becomes an unnoticed no-op.
    try std.testing.expectError(
        error.UnexpectedPositional,
        parseArgs(&.{ "runner", "--strict-gate", "tests/glslang-430" }, &diag),
    );
    try std.testing.expectError(
        error.UnexpectedPositional,
        parseArgs(&.{ "runner", "--strict-gate", "--save-spv", "out.spv" }, &diag),
    );
}

test "the two gate modes cannot be requested together" {
    // The enumerate branch is tested first, so accepting both would let the
    // report silently win over the gate the caller asked for.
    var diag = ArgDiag{};
    try std.testing.expectError(
        error.ConflictingOptions,
        parseArgs(&.{ "runner", "--strict-gate", "--strict-enumerate" }, &diag),
    );
    try std.testing.expectError(
        error.ConflictingOptions,
        parseArgs(&.{ "runner", "--strict-enumerate", "--strict-gate" }, &diag),
    );
}

test "a floor handed to the enumerate report is rejected, not ignored" {
    // --strict-enumerate exits 0 unconditionally, so honoring a floor there is
    // impossible; swallowing the flag would be the same silent-ignore defect
    // the floor exists to rule out.
    var diag = ArgDiag{};
    try std.testing.expectError(
        error.ConflictingOptions,
        parseArgs(&.{ "runner", "--strict-enumerate", "--min-pass=999999" }, &diag),
    );
    try std.testing.expectEqualStrings("--min-pass", diag.arg);

    // The same floor is still accepted by the gate mode.
    const gated = try parse(&.{ "runner", "--strict-gate", "--min-pass=999999" });
    try std.testing.expectEqual(@as(?u32, 999999), gated.min_pass);
}

test "conformance mode still takes a single positional target" {
    const opts = try parse(&.{ "runner", "tests/glslang-430" });
    try std.testing.expectEqualStrings("tests/glslang-430", opts.target.?);
    try std.testing.expect(!opts.strict_gate);
    try std.testing.expectEqual(@as(?u32, null), opts.min_pass);

    var diag = ArgDiag{};
    try std.testing.expectError(
        error.UnexpectedPositional,
        parseArgs(&.{ "runner", "tests/glslang-430", "tests/compute" }, &diag),
    );
}

test "save-spv keeps working in both forms" {
    const separated = try parse(&.{ "runner", "--save-spv", "out.spv", "a.frag" });
    try std.testing.expectEqualStrings("out.spv", separated.save_spv_path.?);
    try std.testing.expectEqualStrings("a.frag", separated.target.?);

    const joined = try parse(&.{ "runner", "--save-spv=out.spv", "a.frag" });
    try std.testing.expectEqualStrings("out.spv", joined.save_spv_path.?);
}

test "no arguments is the plain conformance run" {
    const opts = try parse(&.{"runner"});
    try std.testing.expect(!opts.strict_gate);
    try std.testing.expect(!opts.strict_enumerate);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.target);
    try std.testing.expectEqual(@as(?u32, null), opts.min_pass);
}

// ── zioshade-kgt SPIR-V lint (src/spirv_lint.zig) ─────────────────────
//
// The conformance runner lints every fixture's emitted SPIR-V for the
// dropped-module-scope-runtime-initializer class, so the lint itself is
// pinned here against both the historical bug shape and the fixed shapes.
// The hand-built modules below transcribe the instruction sequence the
// pre-fix compiler actually emitted (verified against a build of the commit
// before the fix: a Private OpVariable with no Initializer operand, loads,
// and no store anywhere).

const lint = zioshade.spirv_lint.globalInitDominance;

// SPIR-V magic + a plausible 1.5 header.
const header = [_]u32{ zioshade.spirv.MAGIC, 0x0001_0500, 0, 64, 0 };

test "kgt lint: uninitialised Private global read in entry function fires" {
    const module = [_]u32{
        header[0], header[1], header[2], header[3], header[4],
        15 | (5 << 16), 4, 10, 0x6E69616D, 0, // OpEntryPoint Fragment %10 "main"
        59 | (4 << 16), 3, 5, 6, // OpVariable Private %5, NO initializer
        54 | (5 << 16), 1, 10, 0, 6, // OpFunction %10 (entry)
        248 | (2 << 16), 11, // OpLabel
        61 | (4 << 16), 3, 12, 5, // OpLoad %12 <- %5 : read before any store
        56 | (1 << 16), // OpFunctionEnd
    };
    const v = lint(&module) orelse return error.ExpectedViolation;
    try std.testing.expectEqual(@as(u32, 5), v.variable_id);
}

test "kgt lint: store before the load satisfies dominance" {
    const module = [_]u32{
        header[0],      header[1], header[2], header[3],  header[4],
        15 | (5 << 16), 4,         10,        0x6E69616D, 0,
        59 | (4 << 16), 3,         5,         6,          54 | (5 << 16),
        1,              10,        0,         6,          248 | (2 << 16),
        11,
        62 | (3 << 16), 5,              13, // OpStore %5 <- %13 (the entry-prologue lowering)
        61 | (4 << 16), 3,              12,
        5,              56 | (1 << 16),
    };
    try std.testing.expectEqual(@as(?zioshade.spirv_lint.GlobalInitViolation, null), lint(&module));
}

test "kgt lint: OpVariable initializer operand satisfies the contract" {
    const module = [_]u32{
        header[0],      header[1], header[2], header[3],  header[4],
        15 | (5 << 16), 4,         10,        0x6E69616D, 0,
        59 | (5 << 16),  3,              5,              6, 9, // OpVariable Private %5 initializer %9
        54 | (5 << 16),  1,              10,             0, 6,
        248 | (2 << 16), 11,             61 | (4 << 16), 3, 12,
        5,               56 | (1 << 16),
    };
    try std.testing.expectEqual(@as(?zioshade.spirv_lint.GlobalInitViolation, null), lint(&module));
}

test "kgt lint: read through OpAccessChain before any store fires" {
    const module = [_]u32{
        header[0],      header[1], header[2], header[3],  header[4],
        15 | (5 << 16), 4,         10,        0x6E69616D, 0,
        59 | (4 << 16), 3,               5,  6, // Private %5 (a vec4)
        54 | (5 << 16), 1,               10, 0,
        6,              248 | (2 << 16), 11,
        65 | (5 << 16), 2, 14, 5, 15, // OpAccessChain %14 = %5[15] (a view)
        61 | (4 << 16), 2, 16, 14, // OpLoad through the view, before any store
        56 | (1 << 16),
    };
    const v = lint(&module) orelse return error.ExpectedViolation;
    try std.testing.expectEqual(@as(u32, 5), v.variable_id);
}

test "kgt lint: helper-function read of a never-written global fires" {
    // The historical shape: the wintty cursor shaders read the global inside
    // mainImage (a HELPER called by main), so entry-only dominance cannot
    // see it. Never-written-anywhere must.
    const module = [_]u32{
        header[0], header[1], header[2], header[3], header[4],
        15 | (5 << 16), 4, 10, 0x6E69616D, 0, // entry is %10 (main)
        59 | (4 << 16), 3, 5, 6, // Private %5, no initializer
        54 | (5 << 16),  1,  10,             0, 6, // main
        248 | (2 << 16), 11, 56 | (1 << 16),
        54 | (5 << 16),  3,  20, 0, 6, // helper %20 (NOT the entry)
        248 | (2 << 16), 21,
        61 | (4 << 16), 3, 22, 5, // load of the never-stored global
        56 | (1 << 16),
    };
    const v = lint(&module) orelse return error.ExpectedViolation;
    try std.testing.expectEqual(@as(u32, 5), v.variable_id);
}

test "kgt lint: helper read of a global stored in the entry prologue passes" {
    const module = [_]u32{
        header[0],      header[1], header[2], header[3],  header[4],
        15 | (5 << 16), 4,         10,        0x6E69616D, 0,
        59 | (4 << 16), 3,         5,         6,          54 | (5 << 16),
        1,              10,        0,         6,          248 | (2 << 16),
        11,
        62 | (3 << 16),  5,              13, // entry prologue store
        56 | (1 << 16),  54 | (5 << 16), 3,
        20,              0,              6,
        248 | (2 << 16), 21,
        61 | (4 << 16), 3, 22, 5, // helper load, dominated via call order
        56 | (1 << 16),
    };
    try std.testing.expectEqual(@as(?zioshade.spirv_lint.GlobalInitViolation, null), lint(&module));
}

test "kgt lint: non-SPIR-V, truncated, and zero-store-free modules stay silent" {
    // Not SPIR-V at all.
    const not_spv = [_]u32{ 0, 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(?zioshade.spirv_lint.GlobalInitViolation, null), lint(&not_spv));
    // SPIR-V header with a declared word count past the end: malformed.
    const truncated = [_]u32{ zioshade.spirv.MAGIC, 0x0001_0500, 0, 64, 0, 15 | (99 << 16), 4, 10 };
    try std.testing.expectEqual(@as(?zioshade.spirv_lint.GlobalInitViolation, null), lint(&truncated));
    // No Private globals: nothing to check.
    const none = [_]u32{
        header[0],      header[1], header[2], header[3],  header[4],
        15 | (5 << 16), 4,         10,        0x6E69616D, 0,
        59 | (4 << 16), 3,               5,  2, // OpVariable Uniform (not Private)
        54 | (5 << 16), 1,               10, 0,
        6,              248 | (2 << 16), 11, 56 | (1 << 16),
    };
    try std.testing.expectEqual(@as(?zioshade.spirv_lint.GlobalInitViolation, null), lint(&none));
}

test "kgt lint: a fixed compiler output passes (uniform-derived global init)" {
    // The real pipeline, not a hand-built module: compile the kgt fixture
    // shape with the current frontend and lint the emitted words. This is
    // the regression the conformance runner enforces on
    // tests/conformance/stress/global_runtime_init_uniform.frag.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(std140, binding = 1) uniform G { vec4 c; };
        \\layout(location = 0) out vec4 o;
        \\vec4 T = vec4(c.rgb * 2.0, c.a);
        \\vec4 shade(float k) { return T * k; }
        \\void main() { o = shade(0.25) + shade(0.75); }
    ;
    const words = try zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(words);
    try std.testing.expectEqual(@as(?zioshade.spirv_lint.GlobalInitViolation, null), lint(words));
}
