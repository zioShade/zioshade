//! Self-tests for the conformance runner's exit decision.
//!
//! The strict gate is the project's headline verification artifact, so the
//! runner must never exit 0 for a run that did not actually verify anything.
//! These tests pin the three ways that used to look green: an empty run, an
//! infrastructure failure, and a pass count under the pinned floor.

const std = @import("std");
const runner = @import("runner.zig");

const Stats = runner.Stats;
const shouldFail = runner.shouldFail;

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
