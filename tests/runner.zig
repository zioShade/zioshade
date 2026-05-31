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
    strict_fp: u32 = 0, // false-positive candidates (tolerate OK, strict fails)

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
        else if (std.mem.endsWith(u8, path, ".mesh"))
            break :blk .mesh
        else if (std.mem.endsWith(u8, path, ".task"))
            break :blk .task
        else if (std.mem.endsWith(u8, path, ".rgen"))
            break :blk .raygen
        else if (std.mem.endsWith(u8, path, ".rchit"))
            break :blk .closesthit
        else if (std.mem.endsWith(u8, path, ".rmiss"))
            break :blk .miss
        else if (std.mem.endsWith(u8, path, ".rahit"))
            break :blk .anyhit
        else if (std.mem.endsWith(u8, path, ".rint"))
            break :blk .intersection
        else if (std.mem.endsWith(u8, path, ".rcall"))
            break :blk .callable
        else
            break :blk .fragment;
    };

    // Compile GLSL -> SPIR-V
    const spirv_ver: glslpp.SPIRVVersion = if (stage == .mesh or stage == .task or
        stage == .raygen or stage == .closesthit or stage == .miss or
        stage == .intersection or stage == .anyhit or stage == .callable) .@"1.4" else .@"1.5";
    const words = glslpp.compileToSPIRV(alloc, source_z, .{ .stage = stage, .spirv_version = spirv_ver }) catch {
        const detail = glslpp.last_compile_detail orelse .semantic_failed;
        const ctx = glslpp.lastErrorCtx() orelse "";
        const inner = glslpp.lastErrorInner() orelse "";
        std.debug.print("  COMPILE-{} {s} ctx={s} inner={s}\n", .{ detail, @tagName(detail), ctx, inner });
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
        log("  spirv-val stderr: {s}\n", .{val_result.stderr});
    }
    if (val_result.stdout.len > 0) {
        log("  spirv-val stdout: {s}\n", .{val_result.stdout});
    }
    return .fail;
}

/// Enumerate false-positive candidates: fixtures where the tolerant compile
/// succeeds but the strict compile fails with error.SemanticFailed.
/// Mirrors testShader's setup (skip logic, include inlining, stage detection)
/// but does NOT run spirv-val.
fn enumerateShader(
    io: compat.IoType,
    alloc: std.mem.Allocator,
    path: []const u8,
    stats: *Stats,
    hist_ctx: [][]const u8,
    hist_cnt: []u32,
    hist_n: *usize,
    max_hist: usize,
) !void {
    const dir = compat.cwd();

    const file = compat.dirOpenFile(io, dir, path, .{}) catch return;
    defer compat.fileClose(io, file);
    const source = try compat.fileReadToEndAlloc(io, file, alloc, 10 * 1024 * 1024);
    const source_z_raw = try alloc.dupeZ(u8, source);
    alloc.free(source);
    const source_nt = source_z_raw;
    defer alloc.free(source_nt);

    // Skip empty files
    if (source_nt.len == 0) return;

    // Skip header/include files (no main function)
    if (std.mem.indexOf(u8, source_nt, "void main") == null and
        std.mem.indexOf(u8, source_nt, "void mainImage") == null)
        return;

    // Skip files that are error-validation tests
    if (std.mem.indexOf(u8, source_nt, "// ERROR") != null) return;

    // Inline #include directives
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
        else if (std.mem.endsWith(u8, path, ".mesh"))
            break :blk .mesh
        else if (std.mem.endsWith(u8, path, ".task"))
            break :blk .task
        else if (std.mem.endsWith(u8, path, ".rgen"))
            break :blk .raygen
        else if (std.mem.endsWith(u8, path, ".rchit"))
            break :blk .closesthit
        else if (std.mem.endsWith(u8, path, ".rmiss"))
            break :blk .miss
        else if (std.mem.endsWith(u8, path, ".rahit"))
            break :blk .anyhit
        else if (std.mem.endsWith(u8, path, ".rint"))
            break :blk .intersection
        else if (std.mem.endsWith(u8, path, ".rcall"))
            break :blk .callable
        else
            break :blk .fragment;
    };

    const spirv_ver: glslpp.SPIRVVersion = if (stage == .mesh or stage == .task or
        stage == .raygen or stage == .closesthit or stage == .miss or
        stage == .intersection or stage == .anyhit or stage == .callable) .@"1.4" else .@"1.5";

    // Tolerate compile: if this fails there is nothing to enumerate.
    const tol_words = glslpp.compileToSPIRV(alloc, source_z, .{ .stage = stage, .spirv_version = spirv_ver }) catch return;
    defer alloc.free(tol_words);

    // Strict compile: a false-positive candidate fires here.
    if (glslpp.compileToSPIRVStrict(alloc, source_z, .{ .stage = stage, .spirv_version = spirv_ver })) |_| {
        // Strict also succeeded: not a false-positive candidate.
        // compileToSPIRVStrict returns a static empty slice — nothing to free.
    } else |err| {
        if (err == error.SemanticFailed) {
            stats.strict_fp += 1;
            const ctx = glslpp.lastErrorCtx() orelse "(none)";
            const inner = glslpp.lastErrorInner() orelse "(none)";
            log("  FP {s} ctx={s} inner={s}\n", .{ path, ctx, inner });

            // Update per-ctx histogram
            var found = false;
            for (hist_ctx[0..hist_n.*], 0..) |existing, hi| {
                if (std.mem.eql(u8, existing, ctx)) {
                    hist_cnt[hi] += 1;
                    found = true;
                    break;
                }
            }
            if (!found and hist_n.* < max_hist) {
                // Dupe ctx into owned memory: lastErrorCtx() returns a slice into
                // an internal buffer that the NEXT compile overwrites, so storing
                // the raw slice would leave the histogram full of dangling/garbled
                // entries. The runner intentionally leaks (GPA reclaims at deinit),
                // so the dup is never explicitly freed.
                hist_ctx[hist_n.*] = alloc.dupe(u8, ctx) catch ctx;
                hist_cnt[hist_n.*] = 1;
                hist_n.* += 1;
            }
        }
        // compileToSPIRVStrict returns a static empty slice on success — nothing to free.
    }
}

fn enumerateDir(
    io: compat.IoType,
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    stats: *Stats,
    hist_ctx: [][]const u8,
    hist_cnt: []u32,
    hist_n: *usize,
    max_hist: usize,
) !void {
    const dir = compat.dirOpenDir(io, compat.cwd(), dir_path, .{ .iterate = true }) catch return;
    defer compat.dirClose(io, dir);

    var walker = try compat.dirWalk(dir, alloc);
    defer walker.deinit();

    while (try compat.walkerNext(io, &walker)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".frag") and !std.mem.eql(u8, ext, ".vert") and
            !std.mem.eql(u8, ext, ".comp") and !std.mem.eql(u8, ext, ".glsl") and
            !std.mem.eql(u8, ext, ".mesh") and !std.mem.eql(u8, ext, ".task") and
            !std.mem.eql(u8, ext, ".geom") and !std.mem.eql(u8, ext, ".tesc") and
            !std.mem.eql(u8, ext, ".tese") and
            !std.mem.eql(u8, ext, ".rgen") and !std.mem.eql(u8, ext, ".rchit") and
            !std.mem.eql(u8, ext, ".rmiss") and !std.mem.eql(u8, ext, ".rahit") and
            !std.mem.eql(u8, ext, ".rint") and !std.mem.eql(u8, ext, ".rcall"))
            continue;

        if (std.mem.indexOf(u8, entry.basename, ".error.") != null) continue;
        if (std.mem.startsWith(u8, entry.basename, "link.")) continue;
        if (std.mem.indexOf(u8, entry.basename, ".asm.") != null) continue;
        if (std.mem.indexOf(u8, entry.basename, ".nocompat.") != null) continue;

        var path_buf: [compat.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.path }) catch continue;

        enumerateShader(io, alloc, full_path, stats, hist_ctx, hist_cnt, hist_n, max_hist) catch {};
    }
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
            !std.mem.eql(u8, ext, ".comp") and !std.mem.eql(u8, ext, ".glsl") and
            !std.mem.eql(u8, ext, ".mesh") and !std.mem.eql(u8, ext, ".task") and
            !std.mem.eql(u8, ext, ".geom") and !std.mem.eql(u8, ext, ".tesc") and
            !std.mem.eql(u8, ext, ".tese") and
            !std.mem.eql(u8, ext, ".rgen") and !std.mem.eql(u8, ext, ".rchit") and
            !std.mem.eql(u8, ext, ".rmiss") and !std.mem.eql(u8, ext, ".rahit") and
            !std.mem.eql(u8, ext, ".rint") and !std.mem.eql(u8, ext, ".rcall"))
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
    var strict_enumerate = false;

    if (!compat.is_0_16) {
        const args = try std.process.argsAlloc(alloc);

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--save-spv") and i + 1 < args.len) {
                save_spv_path = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--strict-enumerate")) {
                strict_enumerate = true;
            } else {
                target_arg = args[i];
            }
        }
        // NOTE: args must NOT be freed until mainImpl returns,
        // because target_arg and save_spv_path point into the args array.
        // We intentionally leak args to avoid use-after-free.
        // The GPA allocator will reclaim all memory on deinit.
    }

    const all_suites = .{
        .{ "glslang-430", "tests/glslang-430" },
        .{ "spirv-cross", "tests/spirv-cross" },
        .{ "ghostty", "tests/ghostty" },
        .{ "mesh-task", "tests/mesh_task" },
        .{ "ray-tracing", "tests/ray_tracing" },
        .{ "compute", "tests/compute" },
        .{ "geometry", "tests/geometry" },
        .{ "tessellation", "tests/tessellation" },
        .{ "stress", "tests/conformance/stress" },
    };

    if (strict_enumerate) {
        // Histogram: linear array of (ctx_slice, count) pairs. N is small (<256).
        const max_hist = 256;
        var hist_ctx: [max_hist][]const u8 = undefined;
        var hist_cnt: [max_hist]u32 = [_]u32{0} ** max_hist;
        var hist_n: usize = 0;

        log("\n=== STRICT-ENUMERATE: false-positive candidates ===\n", .{});
        inline for (all_suites) |suite| {
            log("\n--- {s} ---\n", .{suite.@"0"});
            enumerateDir(io, alloc, suite.@"1", &stats, &hist_ctx, &hist_cnt, &hist_n, max_hist) catch {};
        }

        log("\n=== STRICT-ENUMERATE HISTOGRAM (ctx → count) ===\n", .{});
        for (hist_ctx[0..hist_n], hist_cnt[0..hist_n]) |ctx, cnt| {
            log("  {s}: {d}\n", .{ ctx, cnt });
        }
        log("\n=== STRICT-ENUMERATE SUMMARY ===\n", .{});
        log("False-positive candidates: {d}\n", .{stats.strict_fp});
        log("(see FP lines above for per-fixture ctx= and inner= details)\n", .{});
        // Exit 0 — this is a report, not a gate.
        return;
    }

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
                std.mem.eql(u8, ext, ".comp") or std.mem.eql(u8, ext, ".glsl") or
                std.mem.eql(u8, ext, ".mesh") or std.mem.eql(u8, ext, ".task") or
                std.mem.eql(u8, ext, ".rgen") or std.mem.eql(u8, ext, ".rchit") or
                std.mem.eql(u8, ext, ".rmiss") or std.mem.eql(u8, ext, ".rahit") or
                std.mem.eql(u8, ext, ".rint") or std.mem.eql(u8, ext, ".rcall"))
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
