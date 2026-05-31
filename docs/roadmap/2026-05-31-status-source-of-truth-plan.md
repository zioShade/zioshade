# Status Single-Source-of-Truth — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate every published test/conformance count from a real run so the docs can never silently drift again.

**Architecture:** A pure parse→render Zig tool (`tools/gen_status.zig`, run as `zig build gen-status`) reads three captured suite-output files, parses real totals, then either **writes** `docs/STATUS.md` + injects marker bodies in 5 docs, or **checks** the committed docs against a fresh run. `just update-status` / `just status` orchestrate the (sequential, RAM-safe) suite runs. A checked-in allowlist (`tests/known-conformance-fails.txt`) makes "known feature-gap fail vs regression" an enforced distinction.

**Tech Stack:** Zig 0.15.2 (invoke via `mise exec -- zig`), `just`, the existing `tests/runner.zig` conformance runner. No new third-party deps.

**Design spec:** [`docs/specs/2026-05-31-status-source-of-truth-design.md`](../specs/2026-05-31-status-source-of-truth-design.md)

---

## Conventions for the whole plan

- **Build/test the tool only** (fast, ~1s, no glslpp compile): `mise exec -- zig build test-gen-status --summary all`.
- **Never** run the full `zig build test` more than necessary — it spawns parallel compiles >2 GB RAM. The suite-running recipes invoke one `zig build` at a time.
- All commits authored as `Alessandro De Blasis <alex@deblasis.net>` (git user is already configured; no `--author` needed, but it does no harm).
- The tool is built up across Tasks 1–6 by **appending** functions to a single file `tools/gen_status.zig`. Names used here are final — do not rename between tasks.

## File structure

| File | Responsibility |
|---|---|
| `tools/gen_status.zig` | **new** — arg parse, suite-output parsers, allowlist + regression guard, marker injection, STATUS.md render, write/check `main`, and `test {}` blocks |
| `build.zig` | **modify** — add `gen-status` run step + `test-gen-status` test step (do **not** add to the `test` aggregate, or the tool would count its own tests and perturb `unit.tests`) |
| `justfile` | **modify** — add `update-status`, `status`, `_run-suites`; replace the ad-hoc `summary` recipe |
| `tests/known-conformance-fails.txt` | **new** — allowlist of the 7 known feature-gap fails (`path<TAB># reason`) |
| `docs/STATUS.md` | **new (generated)** — canonical dashboard |
| `.gitignore` | **modify** — ignore `.status-cache/` |
| `README.md`, `docs/TEST_COVERAGE.md`, `docs/IMPLEMENTATION_STATUS.md`, `CONTRIBUTING.md`, `.github/PULL_REQUEST_TEMPLATE.md` | **modify** — wrap restated scalars in `<!-- STATUS:key -->` markers; repoint stale granular tables to `docs/STATUS.md` |

## Shared type & helper reference (defined across Tasks 1–5, listed here so later tasks can refer back)

```zig
const TestSummary = struct { passed: u32, total: u32 };               // Task 1
const SuiteCounts = struct { name: []const u8, pass: u32 = 0, fail: u32 = 0, skip: u32 = 0 }; // Task 2
const ConfSummary = struct { pass: u32 = 0, fail_spirv: u32 = 0, fail_compile: u32 = 0, skip: u32 = 0, total: u32 = 0 }; // Task 2
const ConfResult  = struct { summary: ConfSummary, suites: []SuiteCounts, failing: [][]const u8 }; // Task 2
const AllowEntry  = struct { path: []const u8, reason: []const u8 };  // Task 3
const RegResult   = struct { unexpected: [][]const u8, now_passing: [][]const u8 }; // Task 3
const Kv          = struct { key: []const u8, value: []const u8 };    // Task 4
```

---

## Task 0: Branch hygiene + .gitignore

**Files:**
- Modify: `.gitignore`

> The work branch `docs/status-source-of-truth` already exists off `origin/main`, and the design spec is already committed (`330061ff`). This task only adds the cache-dir ignore.

- [ ] **Step 1: Add `.status-cache/` to `.gitignore`**

Append to `.gitignore`:

```
# status-generator captured suite output (just update-status / just status)
.status-cache/
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: gitignore .status-cache/ for status generator"
```

---

## Task 1: Tool skeleton + `parseBuildSummary` (TDD)

**Files:**
- Create: `tools/gen_status.zig`
- Modify: `build.zig` (add `gen-status` + `test-gen-status` steps)

- [ ] **Step 1: Create `tools/gen_status.zig` with the first parser + its failing test**

Create `tools/gen_status.zig`:

```zig
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
```

- [ ] **Step 2: Wire `gen-status` + `test-gen-status` into `build.zig`**

In `build.zig`, immediately after the `build-runner` step block (the conformance runner wiring ends around `build.zig:182`), insert:

```zig
    // Status generator — run with: zig build gen-status -- <args>
    const gen_status_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_status.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gen_status_step = b.step("gen-status", "Generate/check docs/STATUS.md + status markers");
    const gen_status_exe = b.addExecutable(.{
        .name = "gen-status",
        .root_module = gen_status_mod,
    });
    const run_gen_status = b.addRunArtifact(gen_status_exe);
    if (b.args) |args| {
        for (args) |arg| run_gen_status.addArg(arg);
    }
    gen_status_step.dependOn(&run_gen_status.step);

    // Unit tests for the status generator (intentionally NOT part of `zig build test`,
    // so the tool never counts its own tests into the published unit.tests total).
    const test_gen_status_step = b.step("test-gen-status", "Run gen_status unit tests");
    const run_gen_status_tests = b.addRunArtifact(b.addTest(.{
        .name = "gen-status-tests",
        .root_module = gen_status_mod,
    }));
    test_gen_status_step.dependOn(&run_gen_status_tests.step);
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `mise exec -- zig build test-gen-status --summary all`
Expected: `Build Summary: … ; 2/2 tests passed` (the two `parseBuildSummary` tests).

- [ ] **Step 4: Commit**

```bash
git add tools/gen_status.zig build.zig
git commit -m "feat(tools): gen_status skeleton + parseBuildSummary (TDD)"
```

---

## Task 2: `parseConformance` — per-suite counts, totals, failing set (TDD)

**Files:**
- Modify: `tools/gen_status.zig`

- [ ] **Step 1: Write the failing test**

Append to `tools/gen_status.zig` (before `pub fn main`):

```zig
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
```

- [ ] **Step 2: Run it to confirm it fails to compile (functions undefined)**

Run: `mise exec -- zig build test-gen-status`
Expected: compile error — `parseConformance` / `freeConfResult` undefined.

- [ ] **Step 3: Implement `parseConformance` + helpers**

Append to `tools/gen_status.zig` (before `pub fn main`):

```zig
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- zig build test-gen-status --summary all`
Expected: all tests pass (now 4/4).

- [ ] **Step 5: Commit**

```bash
git add tools/gen_status.zig
git commit -m "feat(tools): gen_status parseConformance with per-suite + cross-check (TDD)"
```

---

## Task 3: Allowlist load + regression guard (TDD)

**Files:**
- Modify: `tools/gen_status.zig`

- [ ] **Step 1: Write the failing test**

Append to `tools/gen_status.zig` (before `pub fn main`):

```zig
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
    var r1 = try checkRegressions(std.testing.allocator, &failing_ok, &allow);
    defer freeRegResult(std.testing.allocator, r1);
    try std.testing.expectEqual(@as(usize, 0), r1.unexpected.len); // x is allowlisted
    try std.testing.expectEqual(@as(usize, 1), r1.now_passing.len); // y no longer fails

    const failing_bad = [_][]const u8{ "a/x.frag", "a/NEW.frag" };
    var r2 = try checkRegressions(std.testing.allocator, &failing_bad, &allow);
    defer freeRegResult(std.testing.allocator, r2);
    try std.testing.expectEqual(@as(usize, 1), r2.unexpected.len);
    try std.testing.expectEqualStrings("a/NEW.frag", r2.unexpected[0]);
}
```

- [ ] **Step 2: Run it to confirm it fails to compile**

Run: `mise exec -- zig build test-gen-status`
Expected: compile error — `loadAllowlist` / `checkRegressions` / free helpers undefined.

- [ ] **Step 3: Implement allowlist + regression guard**

Append to `tools/gen_status.zig` (before `pub fn main`):

```zig
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- zig build test-gen-status --summary all`
Expected: all tests pass (now 6/6).

- [ ] **Step 5: Commit**

```bash
git add tools/gen_status.zig
git commit -m "feat(tools): gen_status allowlist load + regression guard (TDD)"
```

---

## Task 4: `formatThousands` + `injectMarkers` (TDD)

**Files:**
- Modify: `tools/gen_status.zig`

- [ ] **Step 1: Write the failing test**

Append to `tools/gen_status.zig` (before `pub fn main`):

```zig
test "formatThousands inserts comma separators" {
    const a = try formatThousands(std.testing.allocator, 2080);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("2,080", a);
    const b = try formatThousands(std.testing.allocator, 7);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("7", b);
    const c = try formatThousands(std.testing.allocator, 1000000);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("1,000,000", c);
}

test "injectMarkers replaces inner body, leaves the rest untouched" {
    const doc = "before <!-- STATUS:unit.tests -->999<!-- /STATUS --> after";
    const kv = [_]Kv{.{ .key = "unit.tests", .value = "2,004" }};
    const out = try injectMarkers(std.testing.allocator, doc, &kv);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("before <!-- STATUS:unit.tests -->2,004<!-- /STATUS --> after", out);
}

test "injectMarkers errors on unknown key" {
    const doc = "x <!-- STATUS:bogus.key -->0<!-- /STATUS --> y";
    const kv = [_]Kv{.{ .key = "unit.tests", .value = "1" }};
    try std.testing.expectError(error.UnknownStatusKey, injectMarkers(std.testing.allocator, doc, &kv));
}

test "injectMarkers leaves a doc with no markers unchanged" {
    const doc = "plain doc, no markers";
    const kv = [_]Kv{.{ .key = "unit.tests", .value = "1" }};
    const out = try injectMarkers(std.testing.allocator, doc, &kv);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(doc, out);
}
```

- [ ] **Step 2: Run it to confirm it fails to compile**

Run: `mise exec -- zig build test-gen-status`
Expected: compile error — `formatThousands` / `injectMarkers` / `Kv` undefined.

- [ ] **Step 3: Implement `formatThousands` + `injectMarkers`**

Append to `tools/gen_status.zig` (before `pub fn main`):

```zig
const Kv = struct { key: []const u8, value: []const u8 };

fn lookupKv(kv: []const Kv, key: []const u8) ?[]const u8 {
    for (kv) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
    return null;
}

fn formatThousands(alloc: std.mem.Allocator, n: u64) ![]u8 {
    var tmp: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s, 0..) |c, i| {
        if (i != 0 and (s.len - i) % 3 == 0) try out.append(alloc, ',');
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

/// Rewrite the body of every `<!-- STATUS:key -->BODY<!-- /STATUS -->` region
/// with kv[key]. Unknown key -> error.UnknownStatusKey (key printed to stderr).
/// A doc with no markers is returned byte-identical.
fn injectMarkers(alloc: std.mem.Allocator, doc: []const u8, kv: []const Kv) ![]u8 {
    const open = "<!-- STATUS:";
    const open_end = " -->";
    const close = "<!-- /STATUS -->";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, doc, i, open)) |p| {
        try out.appendSlice(alloc, doc[i..p]);
        const key_start = p + open.len;
        const key_end = std.mem.indexOfPos(u8, doc, key_start, open_end) orelse return error.MalformedMarker;
        const key = doc[key_start..key_end];
        const body_start = key_end + open_end.len;
        const body_end = std.mem.indexOfPos(u8, doc, body_start, close) orelse return error.MalformedMarker;
        const value = lookupKv(kv, key) orelse {
            std.debug.print("gen_status: unknown STATUS marker key '{s}'\n", .{key});
            return error.UnknownStatusKey;
        };
        try out.appendSlice(alloc, doc[p..body_start]); // "<!-- STATUS:key -->"
        try out.appendSlice(alloc, value);
        try out.appendSlice(alloc, close);
        i = body_end + close.len;
    }
    try out.appendSlice(alloc, doc[i..]);
    return out.toOwnedSlice(alloc);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- zig build test-gen-status --summary all`
Expected: all tests pass (now 10/10).

- [ ] **Step 5: Commit**

```bash
git add tools/gen_status.zig
git commit -m "feat(tools): gen_status formatThousands + marker injection (TDD)"
```

---

## Task 5: Build the key/value map + render STATUS.md (TDD)

**Files:**
- Modify: `tools/gen_status.zig`

- [ ] **Step 1: Write the failing test**

Append to `tools/gen_status.zig` (before `pub fn main`):

```zig
fn fixtureConfResult(alloc: std.mem.Allocator) !ConfResult {
    var suites = try alloc.alloc(SuiteCounts, 2);
    suites[0] = .{ .name = try alloc.dupe(u8, "glslang-430"), .pass = 35, .fail = 4, .skip = 3 };
    suites[1] = .{ .name = try alloc.dupe(u8, "spirv-cross"), .pass = 2045, .fail = 3, .skip = 5 };
    var failing = try alloc.alloc([]const u8, 1);
    failing[0] = try alloc.dupe(u8, "tests/glslang-430/fp64.desktop.comp");
    return .{
        .summary = .{ .pass = 2080, .fail_spirv = 5, .fail_compile = 2, .skip = 8, .total = 2095 },
        .suites = suites,
        .failing = failing,
    };
}

test "buildKv produces the documented scalar keys" {
    const alloc = std.testing.allocator;
    const conf = try fixtureConfResult(alloc);
    defer freeConfResult(alloc, conf);
    const kv = try buildKv(alloc, .{ .passed = 2004, .total = 2004 }, .{ .passed = 780, .total = 780 }, conf);
    defer freeKv(alloc, kv);
    try std.testing.expectEqualStrings("2,080", lookupKv(kv, "conformance.pass").?);
    try std.testing.expectEqualStrings("7", lookupKv(kv, "conformance.fail").?);
    try std.testing.expectEqualStrings("8", lookupKv(kv, "conformance.skip").?);
    try std.testing.expectEqualStrings("2,095", lookupKv(kv, "conformance.total").?);
    try std.testing.expectEqualStrings("2,087", lookupKv(kv, "conformance.runnable").?);
    try std.testing.expectEqualStrings("2,080 PASS / 7 FAIL / 8 SKIP / 2,095 TOTAL", lookupKv(kv, "conformance.summary").?);
    try std.testing.expectEqualStrings("2,004", lookupKv(kv, "unit.tests").?);
    try std.testing.expectEqualStrings("780", lookupKv(kv, "hlsl.tests").?);
}

test "renderStatusMd is byte-stable and contains headline + a suite row + named fails" {
    const alloc = std.testing.allocator;
    const conf = try fixtureConfResult(alloc);
    defer freeConfResult(alloc, conf);
    var allow = try alloc.alloc(AllowEntry, 1);
    allow[0] = .{ .path = try alloc.dupe(u8, "tests/glslang-430/fp64.desktop.comp"), .reason = try alloc.dupe(u8, "64-bit float not modelled") };
    defer freeAllowlist(alloc, allow);
    const md = try renderStatusMd(alloc, .{ .passed = 2004, .total = 2004 }, .{ .passed = 780, .total = 780 }, conf, allow, "0.15.2");
    defer alloc.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "2,080 PASS / 7 FAIL / 8 SKIP / 2,095 TOTAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "| glslang-430 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "tests/glslang-430/fp64.desktop.comp") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "64-bit float not modelled") != null);
    // byte-stable: no timestamp/SHA -> rendering twice is identical
    const md2 = try renderStatusMd(alloc, .{ .passed = 2004, .total = 2004 }, .{ .passed = 780, .total = 780 }, conf, allow, "0.15.2");
    defer alloc.free(md2);
    try std.testing.expectEqualStrings(md, md2);
}
```

- [ ] **Step 2: Run it to confirm it fails to compile**

Run: `mise exec -- zig build test-gen-status`
Expected: compile error — `buildKv` / `freeKv` / `renderStatusMd` undefined.

- [ ] **Step 3: Implement `buildKv`, `freeKv`, `renderStatusMd` + an `appendf` helper**

Append to `tools/gen_status.zig` (before `pub fn main`):

```zig
fn appendf(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try buf.appendSlice(alloc, s);
}

fn freeKv(alloc: std.mem.Allocator, kv: []Kv) void {
    for (kv) |e| alloc.free(e.value); // keys are string literals; only values are heap
    alloc.free(kv);
}

/// The injectable scalar keys (design spec "Marker scheme"). Conformance `fail`
/// is the combined spirv+compile count; `runnable` = pass + fail.
fn buildKv(alloc: std.mem.Allocator, unit: TestSummary, hlsl: TestSummary, conf: ConfResult) ![]Kv {
    const fail_total = conf.summary.fail_spirv + conf.summary.fail_compile;
    const runnable = conf.summary.pass + fail_total;

    const pass_s = try formatThousands(alloc, conf.summary.pass);
    errdefer alloc.free(pass_s);
    const total_s = try formatThousands(alloc, conf.summary.total);
    errdefer alloc.free(total_s);
    const runnable_s = try formatThousands(alloc, runnable);
    errdefer alloc.free(runnable_s);

    // Success path is leak-clean (caller frees via freeKv). On mid-build OOM the
    // three *_s allocations above are reclaimed by their errdefers; appended
    // allocPrint values would leak, but the tool never runs under OOM pressure
    // (and main uses an arena). Keeping this simple avoids an errdefer that would
    // have to mutate the list it is guarding.
    var kv: std.ArrayListUnmanaged(Kv) = .empty;

    try kv.append(alloc, .{ .key = "conformance.pass", .value = pass_s });
    try kv.append(alloc, .{ .key = "conformance.fail", .value = try std.fmt.allocPrint(alloc, "{d}", .{fail_total}) });
    try kv.append(alloc, .{ .key = "conformance.skip", .value = try std.fmt.allocPrint(alloc, "{d}", .{conf.summary.skip}) });
    try kv.append(alloc, .{ .key = "conformance.total", .value = total_s });
    try kv.append(alloc, .{ .key = "conformance.runnable", .value = runnable_s });
    try kv.append(alloc, .{ .key = "conformance.summary", .value = try std.fmt.allocPrint(alloc, "{s} PASS / {d} FAIL / {d} SKIP / {s} TOTAL", .{ pass_s, fail_total, conf.summary.skip, total_s }) });
    try kv.append(alloc, .{ .key = "unit.tests", .value = try formatThousands(alloc, unit.passed) });
    try kv.append(alloc, .{ .key = "hlsl.tests", .value = try formatThousands(alloc, hlsl.passed) });
    return kv.toOwnedSlice(alloc);
}

fn renderStatusMd(alloc: std.mem.Allocator, unit: TestSummary, hlsl: TestSummary, conf: ConfResult, allow: []const AllowEntry, zig_version: []const u8) ![]u8 {
    const fail_total = conf.summary.fail_spirv + conf.summary.fail_compile;
    const runnable = conf.summary.pass + fail_total;
    const pass_s = try formatThousands(alloc, conf.summary.pass);
    defer alloc.free(pass_s);
    const total_s = try formatThousands(alloc, conf.summary.total);
    defer alloc.free(total_s);
    const runnable_s = try formatThousands(alloc, runnable);
    defer alloc.free(runnable_s);
    const unit_s = try formatThousands(alloc, unit.passed);
    defer alloc.free(unit_s);
    const hlsl_s = try formatThousands(alloc, hlsl.passed);
    defer alloc.free(hlsl_s);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc,
        \\<!-- GENERATED by `just update-status` — do not edit by hand. -->
        \\# glslpp — Status
        \\
        \\Single source of truth for test/conformance counts. Regenerate with
        \\`just update-status`; verify with `just status` (re-runs the suites and
        \\fails if the committed docs drift). Numbers below come from a real run of
        \\`zig build test`, `zig build test-hlsl`, and `zig build conformance`.
        \\
        \\## Conformance (`zig build conformance` — spirv-val oracle)
        \\
        \\
    );
    try appendf(&buf, alloc, "**{s} PASS / {d} FAIL / {d} SKIP / {s} TOTAL** ({s} runnable = pass + known fails).\n\n", .{ pass_s, fail_total, conf.summary.skip, total_s, runnable_s });
    try appendf(&buf, alloc, "The suite exits non-zero while the {d} known feature-gap fails remain — these are pre-existing capability gaps, **not regressions** (see list below).\n\n", .{fail_total});

    try buf.appendSlice(alloc,
        \\| Suite | Pass | Fail | Skip |
        \\|---|---:|---:|---:|
        \\
    );
    for (conf.suites) |s| {
        try appendf(&buf, alloc, "| {s} | {d} | {d} | {d} |\n", .{ s.name, s.pass, s.fail, s.skip });
    }

    try buf.appendSlice(alloc, "\n## Unit & backend tests\n\n| Suite | Command | Tests |\n|---|---|---:|\n");
    try appendf(&buf, alloc, "| Unit (all modules) | `zig build test` | {s} |\n", .{unit_s});
    try appendf(&buf, alloc, "| HLSL backend | `zig build test-hlsl` | {s} |\n", .{hlsl_s});

    try buf.appendSlice(alloc, "\n## Known feature-gap conformance fails (not regressions)\n\nSource of truth: [`tests/known-conformance-fails.txt`](../tests/known-conformance-fails.txt). A failing fixture not on this list aborts `gen-status` as a regression.\n\n| Fixture | Reason |\n|---|---|\n");
    for (allow) |e| {
        try appendf(&buf, alloc, "| `{s}` | {s} |\n", .{ e.path, e.reason });
    }

    try appendf(&buf, alloc, "\n---\n_Generated on Zig {s}. Windows + Vulkan SDK only (the conformance runner hardcodes a Windows `spirv-val.exe` path)._\n", .{zig_version});

    return buf.toOwnedSlice(alloc);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- zig build test-gen-status --summary all`
Expected: all tests pass (now 12/12).

- [ ] **Step 5: Commit**

```bash
git add tools/gen_status.zig
git commit -m "feat(tools): gen_status buildKv + renderStatusMd (TDD)"
```

---

## Task 6: `main` — arg parse, write/check orchestration

**Files:**
- Modify: `tools/gen_status.zig`

> `main` is integration-level (touches the filesystem); it is exercised by Tasks 8/10, not a unit test. Keep it thin — all logic lives in the tested functions above.

- [ ] **Step 1: Replace the placeholder `main` with the real one**

In `tools/gen_status.zig`, replace `pub fn main() !void {}` with:

```zig
const DOCS = [_][]const u8{
    "README.md",
    "docs/TEST_COVERAGE.md",
    "docs/IMPLEMENTATION_STATUS.md",
    "CONTRIBUTING.md",
    ".github/PULL_REQUEST_TEMPLATE.md",
};
const STATUS_MD = "docs/STATUS.md";

const Mode = enum { write, check };

const Args = struct {
    mode: Mode = .check,
    test_path: []const u8 = ".status-cache/test.txt",
    hlsl_path: []const u8 = ".status-cache/hlsl.txt",
    conf_path: []const u8 = ".status-cache/conformance.txt",
    allowlist_path: []const u8 = "tests/known-conformance-fails.txt",
    zig_version: []const u8 = "unknown",
};

fn readFileAll(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(alloc, 16 * 1024 * 1024);
}

fn parseArgs(argv: [][:0]u8) !Args {
    var a = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--mode") and i + 1 < argv.len) {
            i += 1;
            a.mode = if (std.mem.eql(u8, argv[i], "write")) .write else .check;
        } else if (std.mem.eql(u8, arg, "--test") and i + 1 < argv.len) {
            i += 1;
            a.test_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--hlsl") and i + 1 < argv.len) {
            i += 1;
            a.hlsl_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--conf") and i + 1 < argv.len) {
            i += 1;
            a.conf_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--allowlist") and i + 1 < argv.len) {
            i += 1;
            a.allowlist_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--zig-version") and i + 1 < argv.len) {
            i += 1;
            a.zig_version = argv[i];
        }
    }
    return a;
}

pub fn main() !void {
    // Arena over page_allocator: stable API across Zig versions and ideal for a
    // short-lived tool (one deinit frees everything; the per-call frees below are
    // harmless no-ops under the arena but keep intent clear).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const argv = try std.process.argsAlloc(alloc);
    const args = try parseArgs(argv);

    // 1. parse the three captured suite outputs
    const test_txt = try readFileAll(alloc, args.test_path);
    defer alloc.free(test_txt);
    const unit = parseBuildSummary(test_txt) catch |e| {
        std.debug.print("gen_status: failed to parse {s}: {s}\n", .{ args.test_path, @errorName(e) });
        return e;
    };
    if (unit.passed != unit.total) {
        std.debug.print("gen_status: {s} reports {d}/{d} tests passed — failing unit tests, refusing to publish.\n", .{ args.test_path, unit.passed, unit.total });
        std.process.exit(1);
    }

    const hlsl_txt = try readFileAll(alloc, args.hlsl_path);
    defer alloc.free(hlsl_txt);
    const hlsl = try parseBuildSummary(hlsl_txt);
    if (hlsl.passed != hlsl.total) {
        std.debug.print("gen_status: {s} reports {d}/{d} tests passed — failing HLSL tests, refusing to publish.\n", .{ args.hlsl_path, hlsl.passed, hlsl.total });
        std.process.exit(1);
    }

    const conf_txt = try readFileAll(alloc, args.conf_path);
    defer alloc.free(conf_txt);
    const conf = try parseConformance(alloc, conf_txt);
    defer freeConfResult(alloc, conf);

    // 2. regression guard
    const allow_txt = try readFileAll(alloc, args.allowlist_path);
    defer alloc.free(allow_txt);
    const allow = try loadAllowlist(alloc, allow_txt);
    defer freeAllowlist(alloc, allow);
    const allow_paths = try allowPaths(alloc, allow);
    defer alloc.free(allow_paths);
    const reg = try checkRegressions(alloc, conf.failing, allow_paths);
    defer freeRegResult(alloc, reg);
    for (reg.now_passing) |p| std.debug.print("gen_status: NOTE {s} no longer fails — remove it from {s}.\n", .{ p, args.allowlist_path });
    if (reg.unexpected.len > 0) {
        for (reg.unexpected) |p| std.debug.print("gen_status: REGRESSION {s} is failing but is not in {s}.\n", .{ p, args.allowlist_path });
        std.process.exit(1);
    }

    // 3. render
    const kv = try buildKv(alloc, unit, hlsl, conf);
    defer freeKv(alloc, kv);
    const status_md = try renderStatusMd(alloc, unit, hlsl, conf, allow, args.zig_version);
    defer alloc.free(status_md);

    var drift = false;

    // STATUS.md
    if (args.mode == .write) {
        try std.fs.cwd().writeFile(.{ .sub_path = STATUS_MD, .data = status_md });
    } else {
        const cur = readFileAll(alloc, STATUS_MD) catch null;
        if (cur == null or !std.mem.eql(u8, cur.?, status_md)) {
            std.debug.print("gen_status: DRIFT {s} is out of date.\n", .{STATUS_MD});
            drift = true;
        }
    }

    // marker injection in the prose docs
    for (DOCS) |doc| {
        const cur = try readFileAll(alloc, doc);
        defer alloc.free(cur);
        const updated = try injectMarkers(alloc, cur, kv);
        defer alloc.free(updated);
        if (std.mem.eql(u8, cur, updated)) continue;
        if (args.mode == .write) {
            try std.fs.cwd().writeFile(.{ .sub_path = doc, .data = updated });
        } else {
            std.debug.print("gen_status: DRIFT {s} has stale status markers.\n", .{doc});
            drift = true;
        }
    }

    if (args.mode == .check and drift) {
        std.debug.print("gen_status: committed docs do not match a fresh run. Run `just update-status`.\n", .{});
        std.process.exit(1);
    }
    std.debug.print("gen_status: {s} ok ({s} conformance pass, {d} unit, {d} hlsl).\n", .{ @tagName(args.mode), kv[0].value, unit.passed, hlsl.passed });
}
```

- [ ] **Step 2: Verify the whole tool still compiles and unit tests pass**

Run: `mise exec -- zig build test-gen-status --summary all && mise exec -- zig build gen-status -- --help`
Expected: 12/12 tests pass; the `gen-status` exe builds (it will error reading `.status-cache/test.txt` since none exists yet — that is fine, it proves the exe links).

- [ ] **Step 3: Commit**

```bash
git add tools/gen_status.zig
git commit -m "feat(tools): gen_status main — write/check orchestration"
```

---

## Task 7: justfile recipes + retire the ad-hoc `summary`

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Replace the `summary` recipe with status recipes**

In `justfile`, delete the existing `summary` recipe (currently the last recipe, lines ~86-89: the `# show test counts summary` block) and append in its place:

```just
# ── status (single source of truth) ──────────────────────────────────

# internal: run the three suites sequentially (RAM-safe), tee output to .status-cache/
# Shebang recipe so `set -eu` gives deterministic semantics: test/test-hlsl
# failures abort (never publish from a broken run); conformance's expected
# exit(1) for the 7 known fails is swallowed with `|| true` so capture continues.
_run-suites:
    #!/usr/bin/env sh
    set -eu
    mkdir -p .status-cache
    {{zig}} build test --summary all > .status-cache/test.txt 2>&1
    {{zig}} build test-hlsl --summary all > .status-cache/hlsl.txt 2>&1
    {{zig}} build conformance > .status-cache/conformance.txt 2>&1 || true

# regenerate docs/STATUS.md + inject status numbers into the docs
update-status: _run-suites
    {{zig}} build gen-status -- --mode write --test .status-cache/test.txt --hlsl .status-cache/hlsl.txt --conf .status-cache/conformance.txt --allowlist tests/known-conformance-fails.txt --zig-version "$(mise exec -- zig version)"

# verify committed status numbers match a fresh run (CI/pre-commit); no writes, exits non-zero on drift
status: _run-suites
    {{zig}} build gen-status -- --mode check --test .status-cache/test.txt --hlsl .status-cache/hlsl.txt --conf .status-cache/conformance.txt --allowlist tests/known-conformance-fails.txt --zig-version "$(mise exec -- zig version)"
```

> The `-` prefix on the conformance line lets it `exit(1)` (the 7 known fails) without aborting the recipe — the tool's regression guard decides pass/fail. `test`/`test-hlsl` have no `-`, so a genuine unit-test failure stops the recipe before any doc is written.

- [ ] **Step 2: Verify the justfile parses and the recipes are listed**

Run: `just --list`
Expected: `update-status`, `status` appear (and `_run-suites` if private recipes are shown); no parse error.

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "feat(just): update-status / status recipes (single source of truth)"
```

---

## Task 8: Seed the allowlist from a real conformance run

**Files:**
- Create: `tests/known-conformance-fails.txt`

> This is the first heavy run (needs Vulkan SDK / Windows). It captures the REAL failing-fixture paths so the allowlist matches exactly what the runner emits.

- [ ] **Step 1: Run the three suites once, capturing output**

Run:
```bash
just _run-suites
```
Expected: `.status-cache/test.txt`, `.status-cache/hlsl.txt`, `.status-cache/conformance.txt` created. The conformance run prints its `=== SUMMARY ===` block and exits non-zero (expected).

- [ ] **Step 2: Extract the real failing-fixture paths**

Run:
```bash
grep -E "^  FAIL " .status-cache/conformance.txt
```
Expected: 7 lines naming `fp64.desktop.comp`, `int64.desktop.comp`, `newTexture.frag`, `spv.newTexture.frag`, `shader_ballot.*`, `ray_sphere*`, `struct-material.frag` (exact dirs as the runner printed them).

- [ ] **Step 3: Write `tests/known-conformance-fails.txt` using the exact paths from Step 2**

Create `tests/known-conformance-fails.txt` (substitute the exact left-hand paths from the `grep` output; use forward slashes; the reasons below are the canonical ones from the design spec):

```
# Known feature-gap conformance fails — capability gaps, NOT regressions.
# Consumed by `zig build gen-status` (tools/gen_status.zig): a fixture that
# fails spirv-val/compile but is absent here aborts gen-status as a regression.
# Format: <fixture path>   # reason
#
# Wiring the conformance runner itself to XFAIL these is the separate
# analyzer-fail-loud milestone (docs/specs/2026-05-31-analyzer-fail-loud-design.md).

<paste exact path>/fp64.desktop.comp        # 64-bit float type not modelled (honest gap)
<paste exact path>/int64.desktop.comp       # 64-bit int type not modelled (honest gap)
<paste exact path>/newTexture.frag          # OpExtInst word-count on new-form texture builtins
<paste exact path>/spv.newTexture.frag      # OpExtInst word-count on new-form texture builtins
<paste exact path>/shader_ballot.comp       # subgroup ballot feature gap
<paste exact path>/ray_sphere_test.frag     # feature gap
<paste exact path>/struct-material.frag     # feature gap
```

- [ ] **Step 4: Verify the regression guard now passes against the captured run**

Run:
```bash
mise exec -- zig build gen-status -- --mode check --test .status-cache/test.txt --hlsl .status-cache/hlsl.txt --conf .status-cache/conformance.txt --allowlist tests/known-conformance-fails.txt --zig-version "$(mise exec -- zig version)"
```
Expected: **no** `REGRESSION` lines (all 7 fails are allowlisted). It WILL report `DRIFT docs/STATUS.md is out of date` and exit 1 — expected, because STATUS.md doesn't exist yet. If you see any `REGRESSION <path>` line, the allowlist path doesn't match the runner's output — fix the path in `tests/known-conformance-fails.txt`.

- [ ] **Step 5: Commit**

```bash
git add tests/known-conformance-fails.txt
git commit -m "test(conformance): allowlist the 7 known feature-gap fails"
```

---

## Task 9: Insert `<!-- STATUS:key -->` markers into the 5 docs + repoint stale tables

**Files:**
- Modify: `README.md`, `docs/TEST_COVERAGE.md`, `docs/IMPLEMENTATION_STATUS.md`, `CONTRIBUTING.md`, `.github/PULL_REQUEST_TEMPLATE.md`

> One-time hand edits wrapping the existing numbers. Use the exact target strings below; if a `git pull`/rebase changed surrounding text, re-read the line first, then wrap. After this task the numbers are still correct by hand; Task 10 proves the generator reproduces them.

- [ ] **Step 1: README.md — conformance row + WGSL row**

In `README.md:28`, wrap the conformance figures. Replace:
```
| `spirv-val` conformance | **2,080 / 2,087** runnable fixtures pass (`zig build conformance`); 7 known feature-gap failures (64-bit int/float, OpExtInst word-count, shader_ballot, ray_sphere, struct-material), 8 skipped, 2,095 total — see [docs/TEST_COVERAGE.md](docs/TEST_COVERAGE.md) |
```
with:
```
| `spirv-val` conformance | **<!-- STATUS:conformance.pass -->2,080<!-- /STATUS --> / <!-- STATUS:conformance.runnable -->2,087<!-- /STATUS -->** runnable fixtures pass (`zig build conformance`); <!-- STATUS:conformance.fail -->7<!-- /STATUS --> known feature-gap failures (64-bit int/float, OpExtInst word-count, shader_ballot, ray_sphere, struct-material), <!-- STATUS:conformance.skip -->8<!-- /STATUS --> skipped, <!-- STATUS:conformance.total -->2,095<!-- /STATUS --> total — see [docs/STATUS.md](docs/STATUS.md) |
```

- [ ] **Step 2: docs/TEST_COVERAGE.md — three sites**

`docs/TEST_COVERAGE.md:3` (intro): wrap the `2,087 / 2,087`-style figure. Re-read the line, then wrap its pass/total numbers in `<!-- STATUS:conformance.pass -->…<!-- /STATUS -->` and `<!-- STATUS:conformance.runnable -->…<!-- /STATUS -->`, and change any "PASS" phrasing to reference the live count.

`docs/TEST_COVERAGE.md:48` — replace:
```
| **SPIR-V output (the conformance oracle)** | All 2,087 runnable fixtures above | 2,080 pass / 7 known-fail |
```
with:
```
| **SPIR-V output (the conformance oracle)** | All <!-- STATUS:conformance.runnable -->2,087<!-- /STATUS --> runnable fixtures above | <!-- STATUS:conformance.pass -->2,080<!-- /STATUS --> pass / <!-- STATUS:conformance.fail -->7<!-- /STATUS --> known-fail |
```

`docs/TEST_COVERAGE.md:58-59` (Reproducibility block) — replace:
```
zig build conformance               # 2,080/2,087 runnable spirv-val fixtures pass (7 known feature-gap fails)
zig build test --summary all        # 2,054 unit tests across all modules
```
with (note: code-fence text can't hold HTML comments cleanly, so move the live numbers to prose just above the fence and make the fence generic):
```
zig build conformance               # spirv-val conformance suite (see docs/STATUS.md for live counts)
zig build test --summary all        # unit tests across all modules (see docs/STATUS.md)
```
and add a sentence immediately before the fence: `Live counts: <!-- STATUS:conformance.summary -->2,080 PASS / 7 FAIL / 8 SKIP / 2,095 TOTAL<!-- /STATUS -->; <!-- STATUS:unit.tests -->2,054<!-- /STATUS --> unit tests; <!-- STATUS:hlsl.tests -->780<!-- /STATUS --> HLSL tests. See [docs/STATUS.md](./STATUS.md).`

- [ ] **Step 3: docs/IMPLEMENTATION_STATUS.md — wrap scalars, repoint stale tables**

Wrap the conformance scalars at `:13`, `:38`, `:59`, `:169` in `<!-- STATUS:conformance.pass -->` / `conformance.runnable` / `conformance.fail` markers (re-read each line, wrap the `2,080` / `2,087` / `7` it contains).

Repoint the **stale granular tables** to STATUS.md rather than marker-maintaining them:
- §1.6 "Test Coverage" table (`:113-128`, the `1,550` / `22` / `9` … rows): replace the whole table with: `See **[docs/STATUS.md](STATUS.md)** for the live per-suite conformance breakdown and unit/HLSL totals (regenerated by \`just update-status\`).`
- The per-stage "Fragment shaders | … | 1,550 pass" row (`:51`) and similar per-stage counts: replace the stale counts with `see [STATUS.md](STATUS.md)` (leave the ✅ status column).
- §3.3 note at `:181` ("exact per-backend pass counts predate the current corpus … pending regeneration"): update to `Per-suite counts are now generated — see [docs/STATUS.md](STATUS.md).`

- [ ] **Step 4: CONTRIBUTING.md — the gate line**

`CONTRIBUTING.md:33` — replace:
```
   - Any conformance-count delta (`zig build conformance` → 2,080 PASS / 7 known-FAIL / 8 SKIP; the PASS count must not drop and the FAIL count must not grow).
```
with:
```
   - Any conformance-count delta (`zig build conformance` → <!-- STATUS:conformance.summary -->2,080 PASS / 7 FAIL / 8 SKIP / 2,095 TOTAL<!-- /STATUS -->; the PASS count must not drop and the FAIL count must not grow — run `just status` to verify). See [docs/STATUS.md](docs/STATUS.md).
```

- [ ] **Step 5: .github/PULL_REQUEST_TEMPLATE.md — the gate checkbox**

`.github/PULL_REQUEST_TEMPLATE.md:13` — replace:
```
- [ ] `zig build conformance` — 2,080 PASS / 7 known feature-gap FAIL does not regress (PASS must not drop, FAIL must not grow)
```
with:
```
- [ ] `zig build conformance` — <!-- STATUS:conformance.summary -->2,080 PASS / 7 FAIL / 8 SKIP / 2,095 TOTAL<!-- /STATUS --> does not regress (PASS must not drop, FAIL must not grow; `just status` verifies)
```

- [ ] **Step 6: Sanity-check marker balance**

Run:
```bash
grep -rc "STATUS:" README.md docs/TEST_COVERAGE.md docs/IMPLEMENTATION_STATUS.md CONTRIBUTING.md .github/PULL_REQUEST_TEMPLATE.md
```
Expected: each `<!-- STATUS:key -->` has a matching `<!-- /STATUS -->`. Count of `STATUS:` opens == count of `/STATUS` closes across the repo:
```bash
echo "opens: $(grep -ro "STATUS:[a-z.]*" --include=*.md . | wc -l)  closes: $(grep -ro "/STATUS" --include=*.md . | wc -l)"
```

- [ ] **Step 7: Commit**

```bash
git add README.md docs/TEST_COVERAGE.md docs/IMPLEMENTATION_STATUS.md CONTRIBUTING.md .github/PULL_REQUEST_TEMPLATE.md
git commit -m "docs: wrap status numbers in STATUS markers; repoint stale tables to STATUS.md"
```

---

## Task 10: First generation + verification (task requirement)

**Files:**
- Create (generated): `docs/STATUS.md`
- Modify (generated): the 5 marker docs (only if the live numbers differ from the hand-wrapped ones)

- [ ] **Step 1: Generate STATUS.md + sync markers from the captured run**

Using the `.status-cache/*` from Task 8 (no re-run needed):
```bash
mise exec -- zig build gen-status -- --mode write --test .status-cache/test.txt --hlsl .status-cache/hlsl.txt --conf .status-cache/conformance.txt --allowlist tests/known-conformance-fails.txt --zig-version "$(mise exec -- zig version)"
```
Expected: prints `gen_status: write ok (… conformance pass, … unit, … hlsl).`; `docs/STATUS.md` now exists.

- [ ] **Step 2: Inspect the generated STATUS.md and the marker diff**

Run:
```bash
git --no-pager diff --stat
git --no-pager diff README.md docs/TEST_COVERAGE.md docs/IMPLEMENTATION_STATUS.md CONTRIBUTING.md .github/PULL_REQUEST_TEMPLATE.md
```
Expected: `docs/STATUS.md` created. Marker diffs show ONLY number changes where the hand-wrapped value differed from reality (e.g. `2,054`→ the real unit count). If a marker body changed, the hand value was already stale — good, the generator just corrected it.

- [ ] **Step 3: Prove write/check symmetry against the captured run**

Run:
```bash
mise exec -- zig build gen-status -- --mode check --test .status-cache/test.txt --hlsl .status-cache/hlsl.txt --conf .status-cache/conformance.txt --allowlist tests/known-conformance-fails.txt --zig-version "$(mise exec -- zig version)"
```
Expected: `gen_status: check ok (…)` and exit 0 — the docs now match the captured numbers exactly.

- [ ] **Step 4: Prove it against a genuinely FRESH run (the task's "verify against a fresh local run")**

Run:
```bash
just status
```
Expected: re-runs all three suites, then `gen_status: check ok (…)`, exit 0. **Paste the conformance `=== SUMMARY ===` block and this `check ok` line into the PR description as evidence.** If `status` reports DRIFT, the captured run and the fresh run disagree (flaky/changed) — investigate before proceeding.

- [ ] **Step 5: Commit the generated docs**

```bash
git add docs/STATUS.md README.md docs/TEST_COVERAGE.md docs/IMPLEMENTATION_STATUS.md CONTRIBUTING.md .github/PULL_REQUEST_TEMPLATE.md
git commit -m "docs(status): generate docs/STATUS.md + sync live counts into all docs"
```

---

## Task 11: Open the PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin docs/status-source-of-truth
```

- [ ] **Step 2: Open the PR against `deblasis/glslpp`**

```bash
gh pr create --repo deblasis/glslpp --base main --head docs/status-source-of-truth \
  --title "docs: single source of truth for test/conformance counts" \
  --body "<see body template below>"
```

PR body must include:
- **What/Why:** numbers drifted across README/TEST_COVERAGE/IMPLEMENTATION_STATUS/CONTRIBUTING/PR-template (1,996→2,054→2,060 unit; false "2,087/2,087 zero-failures"). Now generated from real runs; closes the `IMPLEMENTATION_STATUS.md:181` "single source of truth for status numbers" cleanup.
- **How:** `tools/gen_status.zig` (`zig build gen-status`), `just update-status` / `just status`, `tests/known-conformance-fails.txt` regression guard, `docs/STATUS.md` + `<!-- STATUS:key -->` markers.
- **Evidence:** the pasted `=== SUMMARY ===` block + `just status` → `check ok` from Task 10 Step 4; `mise exec -- zig build test-gen-status --summary all` → 12/12.
- **Note:** conformance is Windows + Vulkan-SDK only (runner hardcodes the `spirv-val.exe` path); CI red on this repo is the known billing block, not a code failure.
- Footer: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

---

## Self-review checklist (run before handing off)

- [ ] **Spec coverage:** generator (Tasks 1–6) ✓; `just status`/`update-status` (Task 7) ✓; STATUS.md (Task 5/10) ✓; markers (Task 9) ✓; allowlist + named 7 fails (Task 8) ✓; regression guard (Task 3/6) ✓; verification vs fresh run (Task 10 Step 4) ✓; byte-stable STATUS.md (Task 5 test) ✓.
- [ ] **No placeholders:** the only `<paste …>` is Task 8 Step 3, which is intentional (exact paths come from a real run in Step 2) — every other step has complete code.
- [ ] **Type/name consistency:** `TestSummary`, `SuiteCounts`, `ConfSummary`, `ConfResult`, `AllowEntry`, `RegResult`, `Kv` and fns `parseBuildSummary`/`parseConformance`/`loadAllowlist`/`checkRegressions`/`allowPaths`/`formatThousands`/`injectMarkers`/`lookupKv`/`buildKv`/`renderStatusMd`/`freeConfResult`/`freeAllowlist`/`freeRegResult`/`freeKv`/`appendf`/`normalizePath`/`parseTrailingInt`/`readFileAll`/`parseArgs` are used consistently across tasks.
