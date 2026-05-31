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
    // Count of analyzer false-positive candidates (--strict-enumerate mode only):
    // fixtures the tolerate compile accepts but the strict compile rejects.
    strict_fp: u32 = 0,

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
    const stage: glslpp.Stage = stageFromPath(path);

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

/// Detect the shader stage from a fixture path's extension (shared by testShader/enumerateShader).
fn stageFromPath(path: []const u8) glslpp.Stage {
    if (std.mem.endsWith(u8, path, ".vert") or std.mem.endsWith(u8, path, ".v.glsl"))
        return .vertex
    else if (std.mem.endsWith(u8, path, ".comp") or std.mem.endsWith(u8, path, ".c.glsl"))
        return .compute
    else if (std.mem.endsWith(u8, path, ".geom"))
        return .geometry
    else if (std.mem.endsWith(u8, path, ".tesc"))
        return .tessellation_control
    else if (std.mem.endsWith(u8, path, ".tese"))
        return .tessellation_evaluation
    else if (std.mem.endsWith(u8, path, ".mesh"))
        return .mesh
    else if (std.mem.endsWith(u8, path, ".task"))
        return .task
    else if (std.mem.endsWith(u8, path, ".rgen"))
        return .raygen
    else if (std.mem.endsWith(u8, path, ".rchit"))
        return .closesthit
    else if (std.mem.endsWith(u8, path, ".rmiss"))
        return .miss
    else if (std.mem.endsWith(u8, path, ".rahit"))
        return .anyhit
    else if (std.mem.endsWith(u8, path, ".rint"))
        return .intersection
    else if (std.mem.endsWith(u8, path, ".rcall"))
        return .callable
    else
        return .fragment;
}

/// SPIR-V version a fixture compiles against (shared by testShader/enumerateShader
/// so both probe identically — ray-tracing/mesh need 1.4, everything else 1.5).
fn spirvVersionForStage(stage: glslpp.Stage) glslpp.SPIRVVersion {
    return if (stage == .mesh or stage == .task or
        stage == .raygen or stage == .closesthit or stage == .miss or
        stage == .intersection or stage == .anyhit or stage == .callable) .@"1.4" else .@"1.5";
}

/// Whether a directory entry is a conformance fixture we compile. Centralizes the
/// extension allowlist + skip rules so testShader's walk and the enumeration walk
/// select exactly the same corpus (they must not drift).
fn isConformanceFixture(basename: []const u8) bool {
    const ext = std.fs.path.extension(basename);
    if (!std.mem.eql(u8, ext, ".frag") and !std.mem.eql(u8, ext, ".vert") and
        !std.mem.eql(u8, ext, ".comp") and !std.mem.eql(u8, ext, ".glsl") and
        !std.mem.eql(u8, ext, ".mesh") and !std.mem.eql(u8, ext, ".task") and
        !std.mem.eql(u8, ext, ".geom") and !std.mem.eql(u8, ext, ".tesc") and
        !std.mem.eql(u8, ext, ".tese") and
        !std.mem.eql(u8, ext, ".rgen") and !std.mem.eql(u8, ext, ".rchit") and
        !std.mem.eql(u8, ext, ".rmiss") and !std.mem.eql(u8, ext, ".rahit") and
        !std.mem.eql(u8, ext, ".rint") and !std.mem.eql(u8, ext, ".rcall"))
        return false;

    // Skip error-validation tests, multi-file link tests, SPIR-V assembly files, and nocompat.
    if (std.mem.indexOf(u8, basename, ".error.") != null) return false;
    if (std.mem.startsWith(u8, basename, "link.")) return false;
    if (std.mem.indexOf(u8, basename, ".asm.") != null) return false;
    if (std.mem.indexOf(u8, basename, ".nocompat.") != null) return false;
    return true;
}

/// Strict-enumeration probe: compile a fixture with BOTH the tolerate path
/// (`compileToSPIRV`) and the strict path (`compileToSPIRVStrict`). A fixture is
/// a false-positive *candidate* when tolerate SUCCEEDS but strict fails with
/// error.SemanticFailed — i.e. the analyzer over-rejects GLSL that codegen
/// otherwise handles. Records the candidate's `ctx` into `hist` and bumps
/// `stats.strict_fp`. Does NOT run spirv-val (we only care about analyzer
/// accept/reject here).
fn enumerateShader(io: compat.IoType, alloc: std.mem.Allocator, path: []const u8, hist: *std.StringHashMap(u32), stats: *Stats) !void {
    const dir = compat.cwd();

    const file = compat.dirOpenFile(io, dir, path, .{}) catch return;
    defer compat.fileClose(io, file);
    const source = try compat.fileReadToEndAlloc(io, file, alloc, 10 * 1024 * 1024);
    const source_z_raw = try alloc.dupeZ(u8, source);
    alloc.free(source);
    const source_nt = source_z_raw;
    defer alloc.free(source_nt);

    if (source_nt.len == 0) return;
    if (std.mem.indexOf(u8, source_nt, "void main") == null and
        std.mem.indexOf(u8, source_nt, "void mainImage") == null)
        return;
    if (std.mem.indexOf(u8, source_nt, "// ERROR") != null) return;

    const final_source = inlineIncludes(io, alloc, path, source_nt) catch source_nt;
    defer if (final_source.ptr != source_nt.ptr) alloc.free(final_source);
    const source_z = try alloc.dupeZ(u8, final_source);
    defer alloc.free(source_z);

    const stage = stageFromPath(path);
    // Match testShader's version selection so the tolerate probe here cannot
    // succeed/fail differently from the conformance run for RT/mesh stages.
    const spirv_ver = spirvVersionForStage(stage);

    // Tolerate compile: current public behavior. If it fails, this fixture is
    // not a false-positive candidate (the error is not masked today).
    const tolerate_ok = blk: {
        const w = glslpp.compileToSPIRV(alloc, source_z, .{ .stage = stage, .spirv_version = spirv_ver }) catch break :blk false;
        alloc.free(w);
        break :blk true;
    };
    if (!tolerate_ok) return;

    // Strict compile: rejects on the first recorded semantic error. (Analysis-only;
    // spirv_version is irrelevant — it affects codegen, which strict mode skips.)
    if (glslpp.compileToSPIRVStrict(alloc, source_z, .{ .stage = stage })) |w| {
        alloc.free(w); // static empty slice → safe no-op (Allocator.free returns on len==0)
        return; // strict also accepted → not a false-positive
    } else |err| {
        if (err != error.SemanticFailed) return; // lex/parse failure, not a semantic over-rejection
        const ctx = glslpp.lastErrorCtx() orelse "<no-ctx>";
        const inner = glslpp.lastErrorInner() orelse "";
        std.debug.print("  FP-CANDIDATE {s} ctx={s} inner={s}\n", .{ path, ctx, inner });
        stats.strict_fp += 1;
        // Histogram by ctx. The threadlocal ctx is overwritten on the next
        // compile, so dupe the key. The dupe is owned by `hist` and freed by the
        // enumerate-mode defer in mainImpl before hist.deinit().
        const key = alloc.dupe(u8, ctx) catch return;
        const gop = hist.getOrPut(key) catch return;
        if (gop.found_existing) {
            alloc.free(key);
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }
    }
}

fn runDirEnumerate(io: compat.IoType, alloc: std.mem.Allocator, dir_path: []const u8, hist: *std.StringHashMap(u32), stats: *Stats) !void {
    const dir = compat.dirOpenDir(io, compat.cwd(), dir_path, .{ .iterate = true }) catch return;
    defer compat.dirClose(io, dir);

    var walker = try compat.dirWalk(dir, alloc);
    defer walker.deinit();

    while (try compat.walkerNext(io, &walker)) |entry| {
        if (entry.kind != .file) continue;
        if (!isConformanceFixture(entry.basename)) continue;

        var path_buf: [compat.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.path }) catch continue;

        enumerateShader(io, alloc, full_path, hist, stats) catch {};
    }
}

fn runDir(io: compat.IoType, alloc: std.mem.Allocator, dir_path: []const u8, stats: *Stats) !void {
    const dir = compat.dirOpenDir(io, compat.cwd(), dir_path, .{ .iterate = true }) catch return;
    defer compat.dirClose(io, dir);

    var walker = try compat.dirWalk(dir, alloc);
    defer walker.deinit();

    while (try compat.walkerNext(io, &walker)) |entry| {
        if (entry.kind != .file) continue;
        if (!isConformanceFixture(entry.basename)) continue;

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
        var hist = std.StringHashMap(u32).init(alloc);
        defer {
            var key_it = hist.keyIterator();
            while (key_it.next()) |k| alloc.free(k.*);
            hist.deinit();
        }
        log("\n=== STRICT FALSE-POSITIVE ENUMERATION ===\n", .{});
        log("(fixtures the tolerate compile ACCEPTS but the strict compile REJECTS)\n", .{});
        inline for (all_suites) |suite| {
            log("\n--- {s} ---\n", .{suite.@"1"});
            runDirEnumerate(io, alloc, suite.@"1", &hist, &stats) catch {};
        }
        log("\n=== FALSE-POSITIVE HISTOGRAM (by ctx) ===\n", .{});
        var it = hist.iterator();
        while (it.next()) |e| {
            log("  {d:>4}  {s}\n", .{ e.value_ptr.*, e.key_ptr.* });
        }
        log("\nTOTAL FALSE-POSITIVE CANDIDATES: {d}\n", .{stats.strict_fp});
        // Report mode: always exit 0. The gating --strict-gate variant is added in Task F2.
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
