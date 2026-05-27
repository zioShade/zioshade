// SPDX-License-Identifier: MIT OR Apache-2.0
// Real-world corpus walker.
//
// Walks `tests/external/` for `.frag` / `.vert` / `.comp` / `.glsl` files and
// runs each through the full glslpp pipeline:
//
//   GLSL → SPIR-V → {GLSL, HLSL, MSL, WGSL} cross-compile
//
// If `naga` is on PATH, the emitted WGSL is also piped through
// `naga --input-kind wgsl` as an external sanity check. If naga isn't
// available the runner still walks the corpus and reports the glslpp-side
// PASS/FAIL — the external validation step just shows up as "skipped".
//
// Output is per-shader (PASS / FAIL with reason) plus a per-backend summary
// table. The runner is opt-in: it isn't part of the default `test` step. Run
// it explicitly with:
//
//     mise exec -- zig build test-realworld

const std = @import("std");
const glslpp = @import("glslpp");

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
    stage: glslpp.Stage,
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
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const alloc = gpa_impl.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var shader_dir: []const u8 = "tests/external";
    if (args.len >= 2) shader_dir = args[1];

    // Probe naga once up front. If it isn't on PATH we skip the column entirely.
    const naga_available = probeNaga(alloc);

    // Collect shader files
    var shader_files = try std.ArrayList([]const u8).initCapacity(alloc, 64);
    defer {
        for (shader_files.items) |f| alloc.free(f);
        shader_files.deinit(alloc);
    }

    var dir = std.fs.cwd().openDir(shader_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot open shader directory '{s}': {}\n", .{ shader_dir, err });
        std.debug.print("Usage: realworld_tests [shader_directory]\n", .{});
        std.debug.print("Populate tests/external/ with GLSL shaders to test.\n", .{});
        return;
    };
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |entry| {
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
        const res = runShader(alloc, path, stage, naga_available);
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

fn detectStage(path: []const u8) ?glslpp.Stage {
    if (std.mem.endsWith(u8, path, ".vert")) return .vertex;
    if (std.mem.endsWith(u8, path, ".frag")) return .fragment;
    if (std.mem.endsWith(u8, path, ".comp")) return .compute;
    return null;
}

fn runShader(alloc: std.mem.Allocator, path: []const u8, stage: glslpp.Stage, naga_available: bool) PerShaderResult {
    var result: PerShaderResult = .{
        .path = alloc.dupe(u8, path) catch unreachable,
        .stage = stage,
        .statuses = .{ .skip, .skip, .skip, .skip, .skip, .skip },
        .messages = .{ null, null, null, null, null, null },
    };

    // Read source
    const raw = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
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
    const spv = glslpp.compileToSPIRV(alloc, source, .{ .stage = stage }) catch |err| {
        const detail = glslpp.last_compile_detail;
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
    if (glslpp.spirvToGLSL(alloc, spv, .{})) |s| {
        alloc.free(s);
        result.statuses[@intFromEnum(Backend.glsl)] = .pass;
    } else |err| {
        result.statuses[@intFromEnum(Backend.glsl)] = .fail;
        result.messages[@intFromEnum(Backend.glsl)] = std.fmt.allocPrint(alloc, "{}", .{err}) catch null;
    }

    // Stage 3: HLSL
    if (glslpp.spirvToHLSL(alloc, spv, .{})) |s| {
        alloc.free(s);
        result.statuses[@intFromEnum(Backend.hlsl)] = .pass;
    } else |err| {
        result.statuses[@intFromEnum(Backend.hlsl)] = .fail;
        result.messages[@intFromEnum(Backend.hlsl)] = std.fmt.allocPrint(alloc, "{}", .{err}) catch null;
    }

    // Stage 4: MSL
    if (glslpp.spirvToMSL(alloc, spv, .{})) |s| {
        alloc.free(s);
        result.statuses[@intFromEnum(Backend.msl)] = .pass;
    } else |err| {
        result.statuses[@intFromEnum(Backend.msl)] = .fail;
        result.messages[@intFromEnum(Backend.msl)] = std.fmt.allocPrint(alloc, "{}", .{err}) catch null;
    }

    // Stage 5: WGSL (+ naga)
    if (glslpp.spirvToWGSL(alloc, spv, .{})) |wgsl| {
        defer alloc.free(wgsl);
        result.statuses[@intFromEnum(Backend.wgsl)] = .pass;
        if (naga_available) {
            const naga_msg = runNagaValidate(alloc, wgsl) catch |err| blk: {
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

fn probeNaga(alloc: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "naga", "--version" },
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return result.term == .Exited and result.term.Exited == 0;
}

fn runNagaValidate(alloc: std.mem.Allocator, wgsl_source: []const u8) ![]const u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "test.wgsl", .data = wgsl_source });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath("test.wgsl", &path_buf);

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "naga", "--input-kind", "wgsl", tmp_path },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) {
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
