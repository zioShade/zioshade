const std = @import("std");
const glslpp = @import("glslpp");

const FailureCategory = enum {
    frontend_gap,
    wgsl_backend_gap,
    known_limitation,
};

const Result = struct {
    path: []const u8,
    stage: glslpp.Stage,
    category: FailureCategory,
    error_msg: []const u8,
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const alloc = gpa_impl.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var shader_dir: []const u8 = "tests/external";
    if (args.len >= 2) shader_dir = args[1];

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

    std.debug.print("Testing {d} shaders...\n\n", .{shader_files.items.len});

    var passed: u32 = 0;
    var failed = try std.ArrayList(Result).initCapacity(alloc, 16);
    defer {
        for (failed.items) |f| alloc.free(f.error_msg);
        failed.deinit(alloc);
    }

    for (shader_files.items) |path| {
        const stage = detectStage(path) orelse .fragment;
        if (testShader(alloc, path, stage)) |r| {
            try failed.append(alloc, r);
            std.debug.print("  FAIL  {s}: {s}\n", .{ path, r.error_msg });
        } else {
            passed += 1;
            std.debug.print("  PASS  {s}\n", .{path});
        }
    }

    std.debug.print("\n=== Results ===\n", .{});
    std.debug.print("Passed:  {d}/{d}\n", .{ passed, shader_files.items.len });
    std.debug.print("Failed:  {d}/{d}\n", .{ failed.items.len, shader_files.items.len });

    if (failed.items.len > 0) {
        std.debug.print("\n=== Failure Categories ===\n", .{});
        inline for (.{
            FailureCategory.frontend_gap,
            FailureCategory.wgsl_backend_gap,
            FailureCategory.known_limitation,
        }) |cat| {
            var count: u32 = 0;
            for (failed.items) |f| {
                if (f.category == cat) count += 1;
            }
            if (count > 0) {
                std.debug.print("  {s}: {d}\n", .{ @tagName(cat), count });
                for (failed.items) |f| {
                    if (f.category == cat) {
                        std.debug.print("    {s}\n", .{f.path});
                    }
                }
            }
        }
    }
}

fn detectStage(path: []const u8) ?glslpp.Stage {
    if (std.mem.endsWith(u8, path, ".vert")) return .vertex;
    if (std.mem.endsWith(u8, path, ".frag")) return .fragment;
    if (std.mem.endsWith(u8, path, ".comp")) return .compute;
    return null;
}

fn testShader(alloc: std.mem.Allocator, path: []const u8, stage: glslpp.Stage) ?Result {
    // Read source
    const raw = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
        return Result{ .path = path, .stage = stage, .category = .frontend_gap, .error_msg = std.fmt.allocPrint(alloc, "read failed: {}", .{err}) catch "read failed" };
    };
    defer alloc.free(raw);

    // Null-terminate
    var buf = std.ArrayListUnmanaged(u8).initCapacity(alloc, raw.len + 1) catch return null;
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, raw) catch return null;
    buf.append(alloc, 0) catch return null;
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    // Compile GLSL → SPIR-V
    const spv = glslpp.compileToSPIRV(alloc, source, .{ .stage = stage }) catch |err| {
        const detail = glslpp.last_compile_detail;
        const msg = std.fmt.allocPrint(alloc, "compile: {} ({s})", .{ err, if (detail) |d| @tagName(d) else "?" }) catch "compile failed";
        return Result{ .path = path, .stage = stage, .category = .frontend_gap, .error_msg = msg };
    };
    defer alloc.free(spv);

    // Cross-compile SPIR-V → WGSL
    const wgsl = glslpp.spirvToWGSL(alloc, spv, .{}) catch |err| {
        const msg = std.fmt.allocPrint(alloc, "wgsl: {}", .{err}) catch "wgsl failed";
        return Result{ .path = path, .stage = stage, .category = .wgsl_backend_gap, .error_msg = msg };
    };
    defer alloc.free(wgsl);

    // Validate WGSL with naga
    const naga_result = runNagaValidate(alloc, wgsl) catch |err| {
        const msg = std.fmt.allocPrint(alloc, "naga: {}", .{err}) catch "naga failed";
        return Result{ .path = path, .stage = stage, .category = .wgsl_backend_gap, .error_msg = msg };
    };
    defer alloc.free(naga_result);

    if (naga_result.len > 0) {
        const cat: FailureCategory = if (std.mem.indexOf(u8, naga_result, "unsupported") != null)
            .known_limitation
        else
            .wgsl_backend_gap;
        const msg = std.fmt.allocPrint(alloc, "naga: {s}", .{naga_result}) catch "naga validation failed";
        return Result{ .path = path, .stage = stage, .category = cat, .error_msg = msg };
    }

    return null; // success
}

fn runNagaValidate(alloc: std.mem.Allocator, wgsl_source: []const u8) ![]const u8 {
    // Write WGSL to temp file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "test.wgsl", .data = wgsl_source });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath("test.wgsl", &path_buf);

    // Run naga
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
