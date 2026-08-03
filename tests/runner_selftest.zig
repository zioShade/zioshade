//! Self-tests for the conformance runner's exit decision and command line.
//!
//! The strict gate is the project's headline verification artifact, so the
//! runner must never exit 0 for a run that did not actually verify anything.
//! These tests pin the four ways that used to look green: an empty run, an
//! infrastructure failure, a pass count under the pinned floor, and a floor
//! flag that was mistyped and silently swallowed by the argument parser.

const std = @import("std");
const runner = @import("runner.zig");

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
