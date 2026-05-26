// SPDX-License-Identifier: MIT OR Apache-2.0
//! Shared diagnostic-assertion helpers for glslpp tests.

const std = @import("std");
const glslpp = @import("glslpp");

pub const ExpectedDiagnostic = struct {
    line: ?u32 = null,
    column: ?u32 = null,
    kind: ?glslpp.diagnostic.Diagnostic.Kind = null,
    message_contains: ?[]const u8 = null,
    path_contains: ?[]const u8 = null,
};

/// Asserts that at least one Diagnostic in `diags` matches every non-null
/// field of `expect`. Prints the full diagnostic list on mismatch.
pub fn expectDiagnostic(
    diags: []const glslpp.diagnostic.Diagnostic,
    expect: ExpectedDiagnostic,
) !void {
    for (diags) |d| {
        if (expect.line) |l| if (d.line != l) continue;
        if (expect.column) |c| if (d.column != c) continue;
        if (expect.kind) |k| if (d.kind != k) continue;
        if (expect.message_contains) |m|
            if (std.mem.indexOf(u8, d.message, m) == null) continue;
        if (expect.path_contains) |p|
            if (std.mem.indexOf(u8, d.path, p) == null) continue;
        return; // match
    }
    std.debug.print("no diagnostic matched expectation:\n  expect: {any}\n", .{expect});
    for (diags, 0..) |d, i| {
        std.debug.print("  [{d}] {s}:{d}:{d} {s}: {s}\n", .{
            i, d.path, d.line, d.column, @tagName(d.kind), d.message,
        });
    }
    return error.NoMatchingDiagnostic;
}
