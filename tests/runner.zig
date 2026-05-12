const std = @import("std");
const glslpp = @import("glslpp");
const compat = glslpp.compat;

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

fn inlineIncludes(io: compat.IoType, alloc: std.mem.Allocator, path: []const u8, source: []const u8) ![]const u8 {
    const dir = compat.cwd();

    // Check if source has #include
    const include_tag = "#include \"";
    const start = std.mem.indexOf(u8, source, include_tag) orelse return source;

    // Extract include filename
    const filename_start = start + include_tag.len;
    const quote_end = std.mem.indexOfPos(u8, source, filename_start, "\"") orelse return source;
    const include_filename = source[filename_start..quote_end];

    // Build path relative to the source file's directory
    var dir_end = path.len;
    while (dir_end > 0 and path[dir_end - 1] != '/' and path[dir_end - 1] != '\\') dir_end -= 1;
    const dir_part = path[0..dir_end];

    var include_path_buf: [compat.max_path_bytes]u8 = undefined;
    const include_path = std.fmt.bufPrint(&include_path_buf, "{s}{s}", .{ dir_part, include_filename }) catch return source;

    // Read the include file
    const include_file = compat.dirOpenFile(io, dir, include_path, .{}) catch return source;
    defer compat.fileClose(io, include_file);
    const include_source = try compat.fileReadToEndAlloc(io, include_file, alloc, 1024 * 1024);
    defer alloc.free(include_source);

    // Strip #version line from include source
    var include_content: []const u8 = include_source;
    if (std.mem.startsWith(u8, include_content, "#version")) {
        // Skip until newline
        if (std.mem.indexOfScalar(u8, include_content, '\n')) |nl| {
            include_content = include_content[nl + 1..];
        }
    }

    // Find end of #include line
    const line_end = std.mem.indexOfPos(u8, source, quote_end + 1, "\n") orelse source.len;

    // Build result: before + include_content + after
    const before = source[0..start];
    const after = source[line_end..];
    const result = try alloc.alloc(u8, before.len + include_content.len + after.len);
    @memcpy(result[0..before.len], before);
    @memcpy(result[before.len..][0..include_content.len], include_content);
    @memcpy(result[before.len + include_content.len ..], after);
    return result;
}

fn testShader(io: compat.IoType, alloc: std.mem.Allocator, path: []const u8, save_spv: ?[]const u8) !Result {
    const dir = compat.cwd();

    const file = compat.dirOpenFile(io, dir, path, .{}) catch return .skip;
    defer compat.fileClose(io, file);
    const source = try compat.fileReadToEndAlloc(io, file, alloc, 10 * 1024 * 1024);
    // Ensure null-terminated for downstream use
    const source_z_raw = try alloc.dupeZ(u8, source);
    alloc.free(source);
    const source_nt = source_z_raw;
    defer alloc.free(source_nt);

    // Skip empty files
    if (source_nt.len == 0) return .skip;

    // Skip header/include files (no main function)
    if (std.mem.indexOf(u8, source_nt, "void main") == null and
        std.mem.indexOf(u8, source_nt, "void mainImage") == null)
        return .skip;

    // Skip files that are error-validation tests (contain "// ERROR" markers)
    if (std.mem.indexOf(u8, source_nt, "// ERROR") != null) return .skip;

    // Inline #include directives (simple single-level include)
    const final_source = inlineIncludes(io, alloc, path, source_nt) catch source_nt;
    defer if (final_source.ptr != source_nt.ptr) alloc.free(final_source);
    const source_z = try alloc.dupeZ(u8, final_source);
    defer alloc.free(source_z);

    // Detect stage from file extension
    const stage: glslpp.Stage = blk: {
        if (std.mem.endsWith(u8, path, ".vert") or std.mem.endsWith(u8, path, ".v.glsl"))
            break :blk .vertex
        else if (std.mem.endsWith(u8, path, ".comp") or std.mem.endsWith(u8, path, ".c.glsl"))
            break :blk .compute
        else if (std.mem.endsWith(u8, path, ".geom"))
            break :blk .geometry
        else if (std.mem.endsWith(u8, path, ".tesc"))
            break :blk .tessellation_control
        else if (std.mem.endsWith(u8, path, ".tese"))
            break :blk .tessellation_evaluation
        else
            break :blk .fragment;
    };

    // Compile GLSL -> SPIR-V
    const words = glslpp.compileToSPIRV(alloc, source_z, .{ .stage = stage }) catch {
        const detail = glslpp.last_compile_detail orelse .semantic_failed;
        const ctx = glslpp.semantic.last_error_ctx;
        std.debug.print("  COMPILE-{} {s} ctx={s} inner={s}\n", .{ detail, @tagName(detail), ctx, glslpp.semantic.last_error_inner });
        return .compile_error;
    };
    defer alloc.free(words);

    // Write to temp file or specified path
    const tmp_path: []const u8 = if (save_spv) |sp| sp else blk: {
        var buf: [compat.max_path_bytes]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, ".zig-cache/conformance-{}.spv", .{compat.randomInt(u64)}) catch return .skip;
    };
    const tmp_file = compat.dirCreateFile(io, dir, tmp_path, .{}) catch return .skip;
    defer {
        compat.fileClose(io, tmp_file);
        // Keep the file if validation failed, for debugging
    }
    compat.fileWriteAll(io, tmp_file, std.mem.sliceAsBytes(words)) catch return .skip;

    // Run spirv-val
    const val_result = compat.processRun(io, alloc, &.{ SpirvVal, tmp_path }) catch return .fail;
    defer alloc.free(val_result.stdout);
    defer alloc.free(val_result.stderr);

    const exit_code: u32 = val_result.term.exitedCode() orelse 1;

    if (exit_code == 0) return .pass;

    // Print spirv-val error for diagnostics
    if (val_result.stderr.len > 0) {
        log("  spirv-val: {s}\n", .{val_result.stderr});
    }
    return .fail;
}

fn runDir(io: compat.IoType, alloc: std.mem.Allocator, dir_path: []const u8, stats: *Stats) !void {
    const dir = compat.dirOpenDir(io, compat.cwd(), dir_path, .{ .iterate = true }) catch return;
    defer compat.dirClose(io, dir);

    var walker = try compat.dirWalk(dir, alloc);
    defer walker.deinit();

    while (try compat.walkerNext(io, &walker)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".frag") and !std.mem.eql(u8, ext, ".vert") and
            !std.mem.eql(u8, ext, ".comp") and !std.mem.eql(u8, ext, ".glsl"))
            continue;

        // Skip error-validation tests, multi-file link tests, SPIR-V assembly files, and nocompat
        if (std.mem.indexOf(u8, entry.basename, ".error.") != null) continue;
        if (std.mem.startsWith(u8, entry.basename, "link.")) continue;
        if (std.mem.indexOf(u8, entry.basename, ".asm.") != null) continue;
        if (std.mem.indexOf(u8, entry.basename, ".nocompat.") != null) continue;

        var path_buf: [compat.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.path }) catch continue;

        const result = testShader(io, alloc, full_path, null) catch .skip;
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
                log("  SKIP {s}\n", .{full_path});
            },
        }
    }
}

pub fn main() !void {
    try mainImpl();
}

fn mainImpl() !void {
    var gpa_impl = compat.Gpa(.{ .never_unmap = true, .retain_metadata = false }){};
    // Don't check for leaks - compileToSPIRV leaks internal state intentionally
    defer _ = gpa_impl.deinit();
    const alloc = gpa_impl.allocator();

    // Get I/O context
    var main_io = compat.MainIo().init(alloc);
    defer main_io.deinit();
    const io = main_io.io();

    // On 0.15: parse args. On 0.16: args not available from void main, use defaults.
    var stats = Stats{};
    var save_spv_path: ?[]const u8 = null;
    var target_arg: ?[]const u8 = null;

    if (!compat.is_0_16) {
        const args = try std.process.argsAlloc(alloc);
        defer std.process.argsFree(alloc, args);

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--save-spv") and i + 1 < args.len) {
                save_spv_path = args[i + 1];
                i += 1;
            } else {
                target_arg = args[i];
            }
        }
    }

    const all_suites = .{
        .{ "glslang-430", "tests/glslang-430" },
        .{ "spirv-cross", "tests/spirv-cross" },
        .{ "ghostty", "tests/ghostty" },
    };

    if (target_arg) |target| {
        var matched_suite = false;
        inline for (all_suites) |suite| {
            if (std.mem.eql(u8, target, suite.@"0")) {
                log("\n=== {s} ===\n", .{suite.@"0"});
                runDir(io, alloc, suite.@"1", &stats) catch {};
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
                const result = testShader(io, alloc, target, save_spv_path) catch .skip;
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
                runDir(io, alloc, target, &stats) catch {};
            }
        }
    } else {
        inline for (all_suites) |suite| {
            log("\n=== {s} ===\n", .{suite.@"0"});
            runDir(io, alloc, suite.@"1", &stats) catch {};
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
