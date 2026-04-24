const std = @import("std");
const glslpp = @import("glslpp");

const SpirvVal = "C:\\VulkanSDK\\1.4.341.1\\Bin\\spirv-val.exe";

const Result = enum { pass, fail, skip, compile_error };

const Stats = struct {
    pass: u32 = 0,
    fail: u32 = 0,
    skip: u32 = 0,
    compile_error: u32 = 0,

    fn total(self: Stats) u32 {
        return self.pass + self.fail + self.skip + self.compile_error;
    }
};

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn testShader(alloc: std.mem.Allocator, path: []const u8) !Result {
    const file = std.fs.cwd().openFile(path, .{}) catch return .skip;
    defer file.close();
    const source = file.readToEndAllocOptions(alloc, 10 * 1024 * 1024, null, .of(u8), 0) catch return .skip;
    defer alloc.free(source);

    // Skip files that are error-validation tests (contain "// ERROR" markers)
    if (std.mem.indexOf(u8, source, "// ERROR") != null) return .skip;

    const source_z = try alloc.dupeZ(u8, source);
    defer alloc.free(source_z);

    // Detect stage from file extension
    const stage: glslpp.Stage = blk: {
        if (std.mem.endsWith(u8, path, ".vert") or std.mem.endsWith(u8, path, ".v.glsl"))
            break :blk .vertex
        else if (std.mem.endsWith(u8, path, ".comp") or std.mem.endsWith(u8, path, ".c.glsl"))
            break :blk .compute
        else
            break :blk .fragment;
    };

    // Compile GLSL -> SPIR-V
    const words = glslpp.compileToSPIRV(alloc, source_z, .{ .stage = stage }) catch {
        const detail = glslpp.last_compile_detail orelse .semantic_failed;
        const ctx = glslpp.semantic.last_error_ctx;
        std.debug.print("  COMPILE-{} {s} ctx={s}\n", .{ detail, @tagName(detail), ctx });
        return .compile_error;
    };
    defer alloc.free(words);

    // Write to temp file
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&buf, ".zig-cache/conformance-{}.spv", .{std.crypto.random.int(u64)}) catch return .skip;
    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch return .skip;
    defer {
        tmp_file.close();
        // Keep the file if validation failed, for debugging
    }
    try tmp_file.writeAll(std.mem.sliceAsBytes(words));

    // Run spirv-val
    const val_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ SpirvVal, tmp_path },
    }) catch return .fail;
    defer alloc.free(val_result.stdout);
    defer alloc.free(val_result.stderr);

    const exit_code: u32 = switch (val_result.term) {
        .Exited => |c| c,
        else => 1,
    };

    if (exit_code == 0) return .pass;

    // Print spirv-val error for diagnostics
    if (val_result.stderr.len > 0) {
        log("  spirv-val: {s}\n", .{val_result.stderr});
    }
    return .fail;
}

fn runDir(alloc: std.mem.Allocator, dir_path: []const u8, stats: *Stats) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".frag") and !std.mem.eql(u8, ext, ".vert") and
            !std.mem.eql(u8, ext, ".comp") and !std.mem.eql(u8, ext, ".glsl"))
            continue;

        // Skip error-validation tests and multi-file link tests
        if (std.mem.indexOf(u8, entry.basename, ".error.") != null) continue;
        if (std.mem.startsWith(u8, entry.basename, "link.")) continue;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.path }) catch continue;

        const result = testShader(alloc, full_path) catch .skip;
        switch (result) {
            .pass => {
                stats.pass += 1;
                log("  PASS {s}\n", .{full_path});
            },
            .fail => {
                stats.fail += 1;
                log("  FAIL {s} (spirv-val)\n", .{full_path});
            },
            .compile_error => {
                stats.compile_error += 1;
                log("  FAIL {s} (compile error)\n", .{full_path});
            },
            .skip => {
                stats.skip += 1;
            },
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var stats = Stats{};

    const all_suites = .{
        .{ "glslang-430", "tests/glslang-430" },
        .{ "spirv-cross", "tests/spirv-cross" },
        .{ "ghostty", "tests/ghostty" },
    };

    if (args.len > 1) {
        // args[1] can be a suite name ("glslang-430") or a file/dir path
        const target = args[1];
        var matched_suite = false;
        inline for (all_suites) |suite| {
            if (std.mem.eql(u8, target, suite.@"0")) {
                log("\n=== {s} ===\n", .{suite.@"0"});
                runDir(alloc, suite.@"1", &stats) catch {};
                matched_suite = true;
                break;
            }
        }
        if (!matched_suite) {
            // Treat as a direct file or directory path
            const ext = std.fs.path.extension(target);
            if (std.mem.eql(u8, ext, ".frag") or std.mem.eql(u8, ext, ".vert") or
                std.mem.eql(u8, ext, ".comp") or std.mem.eql(u8, ext, ".glsl"))
            {
                const result = testShader(alloc, target) catch .skip;
                switch (result) {
                    .pass => {
                        stats.pass += 1;
                        log("  PASS {s}\n", .{target});
                    },
                    .fail => {
                        stats.fail += 1;
                        log("  FAIL {s} (spirv-val)\n", .{target});
                    },
                    .compile_error => {
                        stats.compile_error += 1;
                        log("  FAIL {s} (compile error)\n", .{target});
                    },
                    .skip => {
                        stats.skip += 1;
                    },
                }
            } else {
                log("\n=== {s} ===\n", .{target});
                runDir(alloc, target, &stats) catch {};
            }
        }
    } else {
        inline for (all_suites) |suite| {
            log("\n=== {s} ===\n", .{suite.@"0"});
            runDir(alloc, suite.@"1", &stats) catch {};
        }
    }

    log("\n=== SUMMARY ===\n", .{});
    log("PASS:           {d}\n", .{stats.pass});
    log("FAIL (spirv):   {d}\n", .{stats.fail});
    log("FAIL (compile): {d}\n", .{stats.compile_error});
    log("SKIP:           {d}\n", .{stats.skip});
    log("TOTAL:          {d}\n", .{stats.total()});

    if (stats.fail > 0 or stats.compile_error > 0) {
        std.process.exit(1);
    }
}
