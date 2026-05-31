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

test "loadAllowlist strips comments/blanks, keeps path + reason, normalizes slashes" {
    const text =
        \\# known feature-gap conformance fails
        \\
        \\tests/glslang-430/fp64.desktop.comp   # 64-bit float not modelled
        \\tests/glslang-430\int64.desktop.comp  # 64-bit int not modelled
    ;
    const entries = try loadAllowlist(std.testing.allocator, text);
    defer freeAllowlist(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("tests/glslang-430/fp64.desktop.comp", entries[0].path);
    try std.testing.expectEqualStrings("64-bit float not modelled", entries[0].reason);
    try std.testing.expectEqualStrings("tests/glslang-430/int64.desktop.comp", entries[1].path);
}

test "checkRegressions flags unexpected fails and now-passing allowlist entries" {
    const allow = [_][]const u8{ "a/x.frag", "a/y.frag" };
    const failing_ok = [_][]const u8{"a/x.frag"};
    const r1 = try checkRegressions(std.testing.allocator, &failing_ok, &allow);
    defer freeRegResult(std.testing.allocator, r1);
    try std.testing.expectEqual(@as(usize, 0), r1.unexpected.len); // x is allowlisted
    try std.testing.expectEqual(@as(usize, 1), r1.now_passing.len); // y no longer fails

    const failing_bad = [_][]const u8{ "a/x.frag", "a/NEW.frag" };
    const r2 = try checkRegressions(std.testing.allocator, &failing_bad, &allow);
    defer freeRegResult(std.testing.allocator, r2);
    try std.testing.expectEqual(@as(usize, 1), r2.unexpected.len);
    try std.testing.expectEqualStrings("a/NEW.frag", r2.unexpected[0]);
}

const AllowEntry = struct { path: []const u8, reason: []const u8 };
const RegResult = struct { unexpected: [][]const u8, now_passing: [][]const u8 };

fn freeAllowlist(alloc: std.mem.Allocator, entries: []AllowEntry) void {
    for (entries) |e| {
        alloc.free(e.path);
        alloc.free(e.reason);
    }
    alloc.free(entries);
}

fn freeRegResult(alloc: std.mem.Allocator, r: RegResult) void {
    for (r.unexpected) |s| alloc.free(s);
    alloc.free(r.unexpected);
    for (r.now_passing) |s| alloc.free(s);
    alloc.free(r.now_passing);
}

/// One fixture per line: `path[ \t]*# reason`. '#'-only and blank lines ignored.
fn loadAllowlist(alloc: std.mem.Allocator, text: []const u8) ![]AllowEntry {
    var list: std.ArrayListUnmanaged(AllowEntry) = .empty;
    errdefer {
        for (list.items) |e| {
            alloc.free(e.path);
            alloc.free(e.reason);
        }
        list.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var path_part = line;
        var reason: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, '#')) |h| {
            path_part = std.mem.trimRight(u8, line[0..h], " \t");
            reason = std.mem.trim(u8, line[h + 1 ..], " \t");
        }
        if (path_part.len == 0) continue;
        const end = std.mem.indexOfAny(u8, path_part, " \t") orelse path_part.len;
        try list.append(alloc, .{
            .path = try normalizePath(alloc, path_part[0..end]),
            .reason = try alloc.dupe(u8, reason),
        });
    }
    return list.toOwnedSlice(alloc);
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

fn allowPaths(alloc: std.mem.Allocator, entries: []const AllowEntry) ![][]const u8 {
    const out = try alloc.alloc([]const u8, entries.len);
    for (entries, 0..) |e, i| out[i] = e.path;
    return out;
}

/// unexpected = failing fixtures NOT in the allowlist (regressions -> caller aborts).
/// now_passing = allowlisted fixtures that no longer fail (caller warns).
fn checkRegressions(alloc: std.mem.Allocator, failing: []const []const u8, allow: []const []const u8) !RegResult {
    var unexpected: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (unexpected.items) |s| alloc.free(s);
        unexpected.deinit(alloc);
    }
    var now_passing: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (now_passing.items) |s| alloc.free(s);
        now_passing.deinit(alloc);
    }
    for (failing) |f| if (!containsStr(allow, f)) try unexpected.append(alloc, try alloc.dupe(u8, f));
    for (allow) |a| if (!containsStr(failing, a)) try now_passing.append(alloc, try alloc.dupe(u8, a));
    return .{
        .unexpected = try unexpected.toOwnedSlice(alloc),
        .now_passing = try now_passing.toOwnedSlice(alloc),
    };
}

pub fn main() !void {}
