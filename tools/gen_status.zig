//! gen_status — single source of truth for glslpp test/conformance counts.
//!
//! Pure parse -> render. Spawns nothing: `just` runs the suites and captures
//! their output; this tool reads those files and either WRITES docs/STATUS.md
//! (+ injects <!-- STATUS:key --> marker bodies in the prose docs) or CHECKS
//! that the committed docs still match a fresh run.
const std = @import("std");

const TestSummary = struct { passed: u32, total: u32 };

/// Parse the aggregate line `Build Summary: A/B steps succeeded; M/N tests passed`
/// emitted by `zig build <step> --summary all`. Robust to surrounding text:
/// it locates " tests passed" and reads the "M/N" group immediately before it.
fn parseBuildSummary(text: []const u8) !TestSummary {
    const marker = " tests passed";
    const idx = std.mem.indexOf(u8, text, marker) orelse return error.NoTestSummary;
    var start = idx;
    while (start > 0) {
        const c = text[start - 1];
        if ((c >= '0' and c <= '9') or c == '/') start -= 1 else break;
    }
    const group = text[start..idx]; // "M/N"
    const slash = std.mem.indexOfScalar(u8, group, '/') orelse return error.BadTestSummary;
    return .{
        .passed = try std.fmt.parseInt(u32, group[0..slash], 10),
        .total = try std.fmt.parseInt(u32, group[slash + 1 ..], 10),
    };
}

test "parseBuildSummary reads M/N tests passed" {
    const sample =
        \\Build Summary: 3/3 steps succeeded; 2004/2004 tests passed
        \\test success
        \\+- run test glslpp-tests 123 passed 5ms MaxRSS:6M
    ;
    const s = try parseBuildSummary(sample);
    try std.testing.expectEqual(@as(u32, 2004), s.passed);
    try std.testing.expectEqual(@as(u32, 2004), s.total);
}

test "parseBuildSummary errors when no summary line" {
    try std.testing.expectError(error.NoTestSummary, parseBuildSummary("nothing here"));
}

pub fn main() !void {}
