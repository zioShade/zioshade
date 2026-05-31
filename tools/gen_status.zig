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

test "parseConformance counts per-suite, collects failing paths, cross-checks totals" {
    const sample =
        \\=== glslang-430 ===
        \\  PASS tests/glslang-430/ok.frag
        \\  FAIL tests/glslang-430/fp64.desktop.comp (compile error)
        \\  FAIL tests/glslang-430/newTexture.frag (spirv-val)
        \\  SKIP tests/glslang-430/header.h
        \\=== spirv-cross ===
        \\  PASS tests/spirv-cross\a.frag
        \\  PASS tests/spirv-cross\b.frag
        \\=== SUMMARY ===
        \\PASS:           3
        \\FAIL (spirv):   1
        \\FAIL (compile): 1
        \\SKIP:           1
        \\TOTAL:          6
    ;
    const r = try parseConformance(std.testing.allocator, sample);
    defer freeConfResult(std.testing.allocator, r);
    try std.testing.expectEqual(@as(u32, 3), r.summary.pass);
    try std.testing.expectEqual(@as(u32, 1), r.summary.fail_spirv);
    try std.testing.expectEqual(@as(u32, 1), r.summary.fail_compile);
    try std.testing.expectEqual(@as(usize, 2), r.suites.len);
    try std.testing.expectEqual(@as(u32, 1), r.suites[0].pass); // glslang-430
    try std.testing.expectEqual(@as(u32, 2), r.suites[0].fail);
    try std.testing.expectEqual(@as(u32, 2), r.suites[1].pass); // spirv-cross
    try std.testing.expectEqual(@as(usize, 2), r.failing.len);
    // backslashes normalized to forward slashes
    try std.testing.expectEqualStrings("tests/glslang-430/fp64.desktop.comp", r.failing[0]);
}

test "parseConformance errors on per-suite vs SUMMARY mismatch" {
    const sample =
        \\=== a ===
        \\  PASS x
        \\=== SUMMARY ===
        \\PASS:           5
        \\FAIL (spirv):   0
        \\FAIL (compile): 0
        \\SKIP:           0
        \\TOTAL:          5
    ;
    try std.testing.expectError(error.ConformancePassMismatch, parseConformance(std.testing.allocator, sample));
}

const SuiteCounts = struct { name: []const u8, pass: u32 = 0, fail: u32 = 0, skip: u32 = 0 };
const ConfSummary = struct { pass: u32 = 0, fail_spirv: u32 = 0, fail_compile: u32 = 0, skip: u32 = 0, total: u32 = 0 };
const ConfResult = struct { summary: ConfSummary, suites: []SuiteCounts, failing: [][]const u8 };

fn freeConfResult(alloc: std.mem.Allocator, r: ConfResult) void {
    for (r.suites) |s| alloc.free(s.name);
    alloc.free(r.suites);
    for (r.failing) |f| alloc.free(f);
    alloc.free(r.failing);
}

/// dupe `p` (trimmed) with all '\\' rewritten to '/' so allowlist matching is
/// stable regardless of the OS path separator the runner emitted.
fn normalizePath(alloc: std.mem.Allocator, p: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, std.mem.trim(u8, p, " \t\r"));
    for (out) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return out;
}

fn parseTrailingInt(line: []const u8) !u32 {
    var i = line.len;
    while (i > 0 and line[i - 1] >= '0' and line[i - 1] <= '9') i -= 1;
    return std.fmt.parseInt(u32, line[i..], 10);
}

fn parseConformance(alloc: std.mem.Allocator, text: []const u8) !ConfResult {
    var suites: std.ArrayListUnmanaged(SuiteCounts) = .empty;
    errdefer {
        for (suites.items) |s| alloc.free(s.name);
        suites.deinit(alloc);
    }
    var failing: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (failing.items) |f| alloc.free(f);
        failing.deinit(alloc);
    }

    var summary = ConfSummary{};
    var have_summary = false;
    var in_summary = false;
    var cur_idx: ?usize = null;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");

        if (std.mem.startsWith(u8, line, "=== ") and std.mem.endsWith(u8, line, " ===")) {
            const name = line[4 .. line.len - 4];
            if (std.mem.eql(u8, name, "SUMMARY")) {
                in_summary = true;
                have_summary = true;
                cur_idx = null;
                continue;
            }
            try suites.append(alloc, .{ .name = try alloc.dupe(u8, name) });
            cur_idx = suites.items.len - 1;
            continue;
        }

        if (in_summary) {
            if (std.mem.startsWith(u8, line, "PASS:")) summary.pass = try parseTrailingInt(line)
            else if (std.mem.startsWith(u8, line, "FAIL (spirv):")) summary.fail_spirv = try parseTrailingInt(line)
            else if (std.mem.startsWith(u8, line, "FAIL (compile):")) summary.fail_compile = try parseTrailingInt(line)
            else if (std.mem.startsWith(u8, line, "SKIP:")) summary.skip = try parseTrailingInt(line)
            else if (std.mem.startsWith(u8, line, "TOTAL:")) summary.total = try parseTrailingInt(line);
            continue;
        }

        if (std.mem.startsWith(u8, line, "  PASS ")) {
            if (cur_idx) |i| suites.items[i].pass += 1;
        } else if (std.mem.startsWith(u8, line, "  SKIP ")) {
            if (cur_idx) |i| suites.items[i].skip += 1;
        } else if (std.mem.startsWith(u8, line, "  FAIL ")) {
            if (cur_idx) |i| suites.items[i].fail += 1;
            const rest = line["  FAIL ".len..];
            const path = if (std.mem.lastIndexOf(u8, rest, " (")) |p| rest[0..p] else rest;
            try failing.append(alloc, try normalizePath(alloc, path));
        }
    }

    if (!have_summary) return error.NoConformanceSummary;

    var sp: u32 = 0;
    var sf: u32 = 0;
    var sk: u32 = 0;
    for (suites.items) |s| {
        sp += s.pass;
        sf += s.fail;
        sk += s.skip;
    }
    if (sp != summary.pass) return error.ConformancePassMismatch;
    if (sf != summary.fail_spirv + summary.fail_compile) return error.ConformanceFailMismatch;
    if (sk != summary.skip) return error.ConformanceSkipMismatch;

    return .{
        .summary = summary,
        .suites = try suites.toOwnedSlice(alloc),
        .failing = try failing.toOwnedSlice(alloc),
    };
}

pub fn main() !void {}
