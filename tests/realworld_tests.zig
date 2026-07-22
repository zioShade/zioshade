// SPDX-License-Identifier: MIT OR Apache-2.0
// Real-world corpus walker.
//
// Walks `tests/external/` for `.frag` / `.vert` / `.comp` / `.glsl` files and
// runs each through the full zioshade pipeline:
//
//   GLSL → SPIR-V → {GLSL, HLSL, MSL, WGSL} cross-compile
//
// If `naga` is on PATH, the emitted WGSL is also piped through
// `naga --input-kind wgsl` as an external sanity check. If naga isn't
// available the runner still walks the corpus and reports the zioshade-side
// PASS/FAIL — the external validation step just shows up as "skipped".
//
// Output is per-shader (PASS / FAIL with reason) plus a per-backend summary
// table. The runner is opt-in: it isn't part of the default `test` step. Run
// it explicitly with:
//
//     mise exec -- zig build test-realworld

const std = @import("std");
const zioshade = @import("zioshade");
const compat = zioshade.compat;

const Backend = enum {
    spirv,
    glsl,
    hlsl,
    msl,
    wgsl,
    naga,

    fn label(b: Backend) []const u8 {
        return switch (b) {
            .spirv => "SPIR-V",
            .glsl => "GLSL  ",
            .hlsl => "HLSL  ",
            .msl => "MSL   ",
            .wgsl => "WGSL  ",
            .naga => "naga  ",
        };
    }
};

const BackendStatus = enum { pass, fail, skip };

const PerShaderResult = struct {
    path: []const u8,
    stage: zioshade.Stage,
    statuses: [6]BackendStatus,
    messages: [6]?[]const u8, // owned by `alloc`, indexed by @intFromEnum(Backend)

    fn deinit(self: *PerShaderResult, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        for (self.messages) |maybe_msg| {
            if (maybe_msg) |m| alloc.free(m);
        }
    }
};

pub fn main() !void {
    var gpa_impl = compat.Gpa(.{}){};
    defer _ = gpa_impl.deinit();
    const alloc = gpa_impl.allocator();

    // I/O context: on 0.16 file/process ops sit behind std.Io; on 0.15 this is void.
    var main_io = compat.MainIo().init(alloc);
    defer main_io.deinit();
    const io = main_io.io();

    // On 0.15: parse args for an optional shader-dir override. On 0.16 args are not
    // reachable from a void main, so we keep the default (mirrors tests/runner.zig).
    var shader_dir: []const u8 = "tests/external";
    var shader_dir_owned: ?[]u8 = null;
    defer if (shader_dir_owned) |s| alloc.free(s);
    if (!compat.is_0_16) {
        const args = try std.process.argsAlloc(alloc);
        defer std.process.argsFree(alloc, args);
        // Own the override so it outlives `args` (freed just below) without leaking.
        if (args.len >= 2) {
            shader_dir_owned = try alloc.dupe(u8, args[1]);
            shader_dir = shader_dir_owned.?;
        }
    }

    // Probe naga once up front. If it isn't on PATH we skip the column entirely.
    const naga_available = probeNaga(io, alloc);

    // Collect shader files
    var shader_files = try std.ArrayList([]const u8).initCapacity(alloc, 64);
    defer {
        for (shader_files.items) |f| alloc.free(f);
        shader_files.deinit(alloc);
    }

    const dir = compat.dirOpenDir(io, compat.cwd(), shader_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open shader directory '{s}': {}\n", .{ shader_dir, err });
        std.debug.print("Usage: realworld_tests [shader_directory]\n", .{});
        std.debug.print("Populate tests/external/ with GLSL shaders to test.\n", .{});
        return;
    };
    defer compat.dirClose(io, dir);

    var walker = try compat.dirWalk(dir, alloc);
    defer walker.deinit();
    while (try compat.walkerNext(io, &walker)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (std.mem.eql(u8, ext, ".frag") or std.mem.eql(u8, ext, ".vert") or
            std.mem.eql(u8, ext, ".comp") or std.mem.eql(u8, ext, ".glsl"))
        {
            const path = try std.fs.path.join(alloc, &.{ shader_dir, entry.path });
            try shader_files.append(alloc, path);
        }
    }

    if (shader_files.items.len == 0) {
        std.debug.print("No shaders found in {s}\n", .{shader_dir});
        return;
    }

    // Stable order for deterministic output.
    std.mem.sort([]const u8, shader_files.items, {}, lessThanPath);

    std.debug.print("Testing {d} shaders from {s}\n", .{ shader_files.items.len, shader_dir });
    std.debug.print("naga: {s}\n\n", .{if (naga_available) "available — validating WGSL output" else "not on PATH — column will be skipped"});

    var results = try std.ArrayList(PerShaderResult).initCapacity(alloc, shader_files.items.len);
    defer {
        for (results.items) |*r| r.deinit(alloc);
        results.deinit(alloc);
    }

    for (shader_files.items) |path| {
        const stage = detectStage(path) orelse .fragment;
        const res = runShader(io, alloc, path, stage, naga_available);
        printShaderRow(res);
        try results.append(alloc, res);
        // Transfer ownership of `path` from shader_files to results.
        // shader_files.path is owned by the original array; we duplicated it inside runShader.
    }

    printSummary(results.items, naga_available);
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn detectStage(path: []const u8) ?zioshade.Stage {
    if (std.mem.endsWith(u8, path, ".vert")) return .vertex;
    if (std.mem.endsWith(u8, path, ".frag")) return .fragment;
    if (std.mem.endsWith(u8, path, ".comp")) return .compute;
    return null;
}

fn runShader(io: compat.IoType, alloc: std.mem.Allocator, path: []const u8, stage: zioshade.Stage, naga_available: bool) PerShaderResult {
    var result: PerShaderResult = .{
        .path = alloc.dupe(u8, path) catch unreachable,
        .stage = stage,
        .statuses = .{ .skip, .skip, .skip, .skip, .skip, .skip },
        .messages = .{ null, null, null, null, null, null },
    };

    // Read source
    const raw = compat.readFileByPath(alloc, path, 10 * 1024 * 1024) catch |err| {
        result.statuses[@intFromEnum(Backend.spirv)] = .fail;
        result.messages[@intFromEnum(Backend.spirv)] = std.fmt.allocPrint(alloc, "read: {}", .{err}) catch null;
        return result;
    };
    defer alloc.free(raw);

    // Null-terminate.
    var buf = std.ArrayListUnmanaged(u8).initCapacity(alloc, raw.len + 1) catch {
        result.statuses[@intFromEnum(Backend.spirv)] = .fail;
        return result;
    };
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, raw) catch {
        result.statuses[@intFromEnum(Backend.spirv)] = .fail;
        return result;
    };
    buf.append(alloc, 0) catch {
        result.statuses[@intFromEnum(Backend.spirv)] = .fail;
        return result;
    };
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    // Stage 1: GLSL → SPIR-V
    const spv = zioshade.compileToSPIRV(alloc, source, .{ .stage = stage }) catch |err| {
        const detail = zioshade.last_compile_detail;
        result.statuses[@intFromEnum(Backend.spirv)] = .fail;
        result.messages[@intFromEnum(Backend.spirv)] = std.fmt.allocPrint(
            alloc,
            "{}{s}{s}",
            .{ err, if (detail != null) " " else "", if (detail) |d| @tagName(d) else "" },
        ) catch null;
        return result;
    };
    defer alloc.free(spv);
    result.statuses[@intFromEnum(Backend.spirv)] = .pass;

    // Stage 2: GLSL
    if (zioshade.spirvToGLSL(alloc, spv, .{})) |s| {
        alloc.free(s);
        result.statuses[@intFromEnum(Backend.glsl)] = .pass;
    } else |err| {
        result.statuses[@intFromEnum(Backend.glsl)] = .fail;
        result.messages[@intFromEnum(Backend.glsl)] = std.fmt.allocPrint(alloc, "{}", .{err}) catch null;
    }

    // Stage 3: HLSL
    if (zioshade.spirvToHLSL(alloc, spv, .{})) |s| {
        alloc.free(s);
        result.statuses[@intFromEnum(Backend.hlsl)] = .pass;
    } else |err| {
        result.statuses[@intFromEnum(Backend.hlsl)] = .fail;
        result.messages[@intFromEnum(Backend.hlsl)] = std.fmt.allocPrint(alloc, "{}", .{err}) catch null;
    }

    // Stage 4: MSL
    if (zioshade.spirvToMSL(alloc, spv, .{})) |s| {
        alloc.free(s);
        result.statuses[@intFromEnum(Backend.msl)] = .pass;
    } else |err| {
        result.statuses[@intFromEnum(Backend.msl)] = .fail;
        result.messages[@intFromEnum(Backend.msl)] = std.fmt.allocPrint(alloc, "{}", .{err}) catch null;
    }

    // Stage 5: WGSL (+ naga)
    if (zioshade.spirvToWGSL(alloc, spv, .{})) |wgsl| {
        defer alloc.free(wgsl);
        result.statuses[@intFromEnum(Backend.wgsl)] = .pass;
        if (naga_available) {
            const naga_msg = runNagaValidate(io, alloc, wgsl) catch |err| blk: {
                break :blk std.fmt.allocPrint(alloc, "naga subprocess: {}", .{err}) catch null;
            };
            if (naga_msg) |m| {
                if (m.len == 0) {
                    alloc.free(m);
                    result.statuses[@intFromEnum(Backend.naga)] = .pass;
                } else {
                    result.statuses[@intFromEnum(Backend.naga)] = .fail;
                    result.messages[@intFromEnum(Backend.naga)] = m;
                }
            } else {
                result.statuses[@intFromEnum(Backend.naga)] = .pass;
            }
        }
    } else |err| {
        result.statuses[@intFromEnum(Backend.wgsl)] = .fail;
        result.messages[@intFromEnum(Backend.wgsl)] = std.fmt.allocPrint(alloc, "{}", .{err}) catch null;
        // naga column stays as .skip since there's no WGSL to validate.
    }

    return result;
}

fn probeNaga(io: compat.IoType, alloc: std.mem.Allocator) bool {
    const result = compat.processRun(io, alloc, &.{ "naga", "--version" }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return (result.term.exitedCode() orelse 1) == 0;
}

fn runNagaValidate(io: compat.IoType, alloc: std.mem.Allocator, wgsl_source: []const u8) ![]const u8 {
    // Stage the WGSL under the OS temp dir (compat picks a writable, portable
    // location and hides the 0.15/0.16 absolute-file split), then run naga on it.
    const tmp_path = try compat.tempFilePathFmt(alloc, "zioshade-naga-{x}.wgsl", .{compat.randomInt(u64)});
    defer alloc.free(tmp_path);
    try compat.writeFileAbsolute(alloc, tmp_path, wgsl_source);
    defer compat.deleteFileAbsolute(alloc, tmp_path) catch {};

    const result = try compat.processRun(io, alloc, &.{ "naga", "--input-kind", "wgsl", tmp_path });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if ((result.term.exitedCode() orelse 1) == 0) {
        return try alloc.dupe(u8, "");
    }
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ result.stdout, result.stderr });
}

fn statusGlyph(s: BackendStatus) []const u8 {
    return switch (s) {
        .pass => "PASS",
        .fail => "FAIL",
        .skip => " -- ",
    };
}

fn printShaderRow(r: PerShaderResult) void {
    std.debug.print("{s} [{s}]\n", .{ r.path, @tagName(r.stage) });
    inline for (.{ Backend.spirv, Backend.glsl, Backend.hlsl, Backend.msl, Backend.wgsl, Backend.naga }) |b| {
        const idx = @intFromEnum(b);
        const status = r.statuses[idx];
        const msg = r.messages[idx];
        if (status == .fail and msg != null) {
            std.debug.print("    {s} {s}  -- {s}\n", .{ b.label(), statusGlyph(status), msg.? });
        } else {
            std.debug.print("    {s} {s}\n", .{ b.label(), statusGlyph(status) });
        }
    }
}

fn printSummary(results: []const PerShaderResult, naga_available: bool) void {
    const total = results.len;
    var pass_counts: [6]u32 = .{0} ** 6;
    var fail_counts: [6]u32 = .{0} ** 6;
    var skip_counts: [6]u32 = .{0} ** 6;

    for (results) |r| {
        inline for (.{ Backend.spirv, Backend.glsl, Backend.hlsl, Backend.msl, Backend.wgsl, Backend.naga }) |b| {
            const idx = @intFromEnum(b);
            switch (r.statuses[idx]) {
                .pass => pass_counts[idx] += 1,
                .fail => fail_counts[idx] += 1,
                .skip => skip_counts[idx] += 1,
            }
        }
    }

    std.debug.print("\n=== Per-backend summary ===\n", .{});
    std.debug.print("Backend  | PASS | FAIL | SKIP | Total\n", .{});
    std.debug.print("---------|------|------|------|------\n", .{});
    inline for (.{ Backend.spirv, Backend.glsl, Backend.hlsl, Backend.msl, Backend.wgsl, Backend.naga }) |b| {
        const idx = @intFromEnum(b);
        std.debug.print("{s}   | {d:>4} | {d:>4} | {d:>4} | {d:>4}\n", .{
            b.label(),
            pass_counts[idx],
            fail_counts[idx],
            skip_counts[idx],
            total,
        });
    }

    if (!naga_available) {
        std.debug.print("\nnaga not on PATH; WGSL outputs were generated but not externally validated.\n", .{});
    }

    // Bail out non-zero if SPIR-V (the oracle) ever fails.
    if (fail_counts[@intFromEnum(Backend.spirv)] > 0) {
        std.debug.print("\nFAILURE: SPIR-V compile failed on {d} shader(s).\n", .{fail_counts[@intFromEnum(Backend.spirv)]});
        std.process.exit(1);
    }
}
