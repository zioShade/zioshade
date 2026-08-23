const std = @import("std");
const zioshade = @import("zioshade");
const compat = zioshade.compat;

/// `infra_error` is distinct from `skip`: it means the harness itself broke
/// (local I/O, formatting, an unexpected error from the compiler entry point),
/// not that the fixture was legitimately not applicable. It always forces a
/// non-zero exit, so a broken harness can never look like a green run.
const Result = enum { pass, fail, skip, compile_error, infra_error };

pub const Stats = struct {
    pass: u32 = 0,
    fail: u32 = 0,
    skip: u32 = 0,
    compile_error: u32 = 0,
    infra_error: u32 = 0, // harness/infrastructure failures (never a legitimate skip)
    strict_fp: u32 = 0, // false-positive candidates (tolerate OK, strict fails)
    xfail: u32 = 0, // expected failures (known-unsupported fixtures)

    pub fn total(self: Stats) u32 {
        return self.pass + self.fail + self.skip + self.compile_error + self.infra_error + self.xfail;
    }
};

/// Pure exit decision for the runner. Non-zero exit when anything really
/// failed, when the harness broke, when nothing ran at all, or when the pass
/// count is under the caller-supplied floor.
pub fn shouldFail(stats: Stats, min_pass: ?u32) bool {
    if (stats.fail > 0 or stats.compile_error > 0 or stats.infra_error > 0) return true;
    if (stats.total() == 0) return true;
    if (min_pass) |floor| {
        if (stats.pass < floor) return true;
    }
    return false;
}

/// Print the reasons that are not already obvious from the per-fixture log.
fn reportExitReasons(stats: Stats, min_pass: ?u32) void {
    if (stats.infra_error > 0)
        log("FAIL: {d} infrastructure error(s), see INFRA-ERROR lines above\n", .{stats.infra_error});
    if (stats.total() == 0)
        log("FAIL: no fixtures ran at all (TOTAL 0), the fixture tree or the walker is broken\n", .{});
    if (min_pass) |floor| {
        if (stats.pass < floor)
            log("FAIL: expected at least {d} passing fixtures, got {d}\n", .{ floor, stats.pass });
    }
}

/// Paths of fixtures that are expected to fail after the fail-loud flip.
/// These are either genuinely unrepresentable constructs (extensions not modeled,
/// 64-bit types, AMD-specific ops) or current spirv-val failures.
/// Match by path suffix — full "tests/<suite>/<name>" to avoid over-matching
/// (e.g. "newTexture.frag" is a suffix of "spv.newTexture.frag").
const KNOWN_UNSUPPORTED = [_][]const u8{
    "tests/glslang-430/newTexture.frag",
    "tests/glslang-430/spv.newTexture.frag",
    "tests/glslang-430/spv.AofA.frag",
    "tests/glslang-430/spv.double.comp",
    "tests/glslang-430/spv.nvAtomicFp16Vec.frag",
    // extended-arithmetic.desktop.comp was unsupported only because the 64-bit
    // umul/imulExtended product wasn't lowered; the scalar AND component-wise vector
    // forms are now emulated with core u32 ops, so it compiles + spirv-vals.
    "tests/spirv-cross/fp64.desktop.comp",
    "tests/spirv-cross/gcn_shader.comp",
    // image-query.desktop.frag was unsupported only because samplerCubeArray /
    // imageCubeArray were mis-compiled (#183); it now compiles + spirv-vals.
    "tests/spirv-cross/int64.desktop.comp",
    // ray_sphere_test.frag was unsupported only because multi-declarator struct
    // members (`struct Ray { vec3 o, d; }`) were mis-parsed; it now compiles +
    // spirv-vals (the struct/uniform-block parser handles comma-separated names).
    "tests/spirv-cross/shader-clock.frag",
    "tests/spirv-cross/shader_ballot.comp",
    "tests/spirv-cross/struct-material.frag",
    // Deliberate honest-error (documented in docs/IMPLEMENTATION_STATUS.md 3.6, with a
    // regression test in tests/correctness_tests.zig). ubo_layout shares one struct type
    // across two UBOs with conflicting row/column-major matrix layout (a single SPIR-V
    // struct type can carry only one), #521; it fails loud rather than emit a silent-wrong
    // translation. (loop-dominator-and-switch-default was previously listed here for a
    // `continue` in a switch-default the frontend could not structurize; the frontend now
    // resolves it correctly and deadLoopElim keeps its live loop, so it compiles + passes.)
    "tests/spirv-cross/ubo_layout.frag",
};

fn isKnownUnsupported(path: []const u8) bool {
    for (KNOWN_UNSUPPORTED) |p| if (std.mem.endsWith(u8, path, p)) return true;
    return false;
}

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
            include_content = include_content[nl + 1 ..];
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

    // The walker already told us this path exists, so failing to open it is the
    // harness breaking, not a fixture that does not apply.
    const file = compat.dirOpenFile(io, dir, path, .{}) catch return .infra_error;
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
    const stage: zioshade.Stage = blk: {
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
    const spirv_ver: zioshade.SPIRVVersion = if (stage == .mesh or stage == .task or
        stage == .raygen or stage == .closesthit or stage == .miss or
        stage == .intersection or stage == .anyhit or stage == .callable) .@"1.4" else .@"1.5";
    const words = zioshade.compileToSPIRV(alloc, source_z, .{ .stage = stage, .spirv_version = spirv_ver }) catch {
        const detail = zioshade.last_compile_detail orelse .semantic_failed;
        const ctx = zioshade.lastErrorCtx() orelse "";
        const inner = zioshade.lastErrorInner() orelse "";
        std.debug.print("  COMPILE-{} {s} ctx={s} inner={s}\n", .{ detail, @tagName(detail), ctx, inner });
        return .compile_error;
    };
    defer alloc.free(words);

    // Structural silent-wrong lint (zioshade-kgt class): a module-scope
    // non-constant initializer must survive lowering as an OpVariable
    // initializer or a store that dominates every read. spirv-val cannot see
    // this class (the module is valid), so it is checked here, before the
    // oracle run, on every fixture that reaches this point.
    if (zioshade.spirv_lint.globalInitDominance(words)) |v| {
        log("  LINT {s} (Private %{d} read before any dominating store; zioshade-kgt class)\n", .{ path, v.variable_id });
        return .fail;
    }

    // Write to temp file or specified path. These three are local I/O and
    // formatting, so a failure is the harness breaking, not a missing tool:
    // report .infra_error, never .skip.
    const tmp_path: []const u8 = if (save_spv) |sp| sp else blk: {
        var buf: [compat.max_path_bytes]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, ".zig-cache/conformance-{}.spv", .{compat.randomInt(u64)}) catch return .infra_error;
    };
    const tmp_file = compat.dirCreateFile(io, dir, tmp_path, .{}) catch return .infra_error;
    defer {
        compat.fileClose(io, tmp_file);
        // Keep the file if validation failed, for debugging
    }
    compat.fileWriteAll(io, tmp_file, std.mem.sliceAsBytes(words)) catch return .infra_error;

    // Run spirv-val. Degrade to .skip (not .fail) when it cannot be spawned at
    // all — e.g. VULKAN_SDK unset and no spirv-val on PATH — so a missing tool
    // doesn't masquerade as a conformance failure.
    const spirv_val = compat.resolveSpirvVal(alloc) catch return .skip;
    defer alloc.free(spirv_val);
    const val_result = compat.processRun(io, alloc, &.{ spirv_val, tmp_path }) catch return .skip;
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
    const stage: zioshade.Stage = blk: {
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

    const spirv_ver: zioshade.SPIRVVersion = if (stage == .mesh or stage == .task or
        stage == .raygen or stage == .closesthit or stage == .miss or
        stage == .intersection or stage == .anyhit or stage == .callable) .@"1.4" else .@"1.5";

    // Tolerate compile: if this fails there is nothing to enumerate.
    const tol_words = zioshade.compileToSPIRV(alloc, source_z, .{ .stage = stage, .spirv_version = spirv_ver }) catch return;
    defer alloc.free(tol_words);

    // Strict compile: a false-positive candidate fires here.
    if (zioshade.compileToSPIRVStrict(alloc, source_z, .{ .stage = stage, .spirv_version = spirv_ver })) |_| {
        // Strict also succeeded: not a false-positive candidate.
        // compileToSPIRVStrict returns a static empty slice — nothing to free.
    } else |err| {
        if (err == error.SemanticFailed) {
            stats.strict_fp += 1;
            const ctx = zioshade.lastErrorCtx() orelse "(none)";
            const inner = zioshade.lastErrorInner() orelse "(none)";
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
    // A fixture directory that cannot be opened (renamed, deleted, unreadable)
    // must be loud. Returning void here used to make a whole missing suite
    // indistinguishable from a suite in which everything passed.
    const dir = compat.dirOpenDir(io, compat.cwd(), dir_path, .{ .iterate = true }) catch return error.FixtureDirUnavailable;
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

        const result = testShader(io, alloc, full_path, null) catch |err| blk: {
            log("  INFRA-ERROR {s} ({s})\n", .{ full_path, @errorName(err) });
            break :blk Result.infra_error;
        };
        const known = isKnownUnsupported(full_path);
        switch (result) {
            .pass => {
                if (known) {
                    // A KNOWN_UNSUPPORTED fixture unexpectedly passed — the list is stale.
                    // Fail loudly so it can be removed from the list and re-classified.
                    stats.fail += 1;
                    log("  UNEXPECTED-PASS {s} (was KNOWN_UNSUPPORTED — remove from list)\n", .{full_path});
                } else {
                    stats.pass += 1;
                    log("  PASS {s}\n", .{full_path});
                }
            },
            .fail => {
                if (known) {
                    stats.xfail += 1;
                    log("  XFAIL {s} (spirv-val, known-unsupported)\n", .{full_path});
                } else {
                    stats.fail += 1;
                    log("  FAIL {s} (spirv-val)\n", .{full_path});
                }
            },
            .compile_error => {
                if (known) {
                    stats.xfail += 1;
                    log("  XFAIL {s} (compile error, known-unsupported)\n", .{full_path});
                } else {
                    stats.compile_error += 1;
                    log("  FAIL {s} (compile error)\n", .{full_path});
                }
            },
            .skip => {
                stats.skip += 1;
                log("  SKIP {s}\n", .{full_path});
            },
            .infra_error => {
                stats.infra_error += 1;
                log("  INFRA-ERROR {s} (harness I/O failure)\n", .{full_path});
            },
        }
    }
}

/// Strict-gate: walk a suite directory, compile each fixture with compileToSPIRV
/// (fail-loud mode since the flip), and report any rejection NOT in KNOWN_UNSUPPORTED
/// as a false-positive regression (exit non-zero). Does NOT run spirv-val.
fn strictGateDir(
    io: compat.IoType,
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    stats: *Stats,
) !void {
    const dir = compat.dirOpenDir(io, compat.cwd(), dir_path, .{ .iterate = true }) catch return error.FixtureDirUnavailable;
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

        // The walker already found these files, so a path that will not format,
        // will not open, or will not read is the harness breaking. Dropping any
        // of them with a bare `continue` removes the fixture from the totals
        // with no diagnostic and no exit-code effect, which is exactly the gate
        // that cannot fail honestly. Route them all through .infra_error.
        var path_buf: [compat.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.path }) catch |err| {
            stats.infra_error += 1;
            log("  INFRA-ERROR {s}/{s} ({s})\n", .{ dir_path, entry.path, @errorName(err) });
            continue;
        };

        // Apply same skip logic as testShader
        const file = compat.dirOpenFile(io, compat.cwd(), full_path, .{}) catch |err| {
            stats.infra_error += 1;
            log("  INFRA-ERROR {s} ({s})\n", .{ full_path, @errorName(err) });
            continue;
        };
        defer compat.fileClose(io, file);
        const source = compat.fileReadToEndAlloc(io, file, alloc, 10 * 1024 * 1024) catch |err| {
            stats.infra_error += 1;
            log("  INFRA-ERROR {s} ({s})\n", .{ full_path, @errorName(err) });
            continue;
        };
        defer alloc.free(source);
        if (source.len == 0) continue;
        if (std.mem.indexOf(u8, source, "void main") == null and
            std.mem.indexOf(u8, source, "void mainImage") == null) continue;
        if (std.mem.indexOf(u8, source, "// ERROR") != null) continue;

        const final_source = inlineIncludes(io, alloc, full_path, source) catch source;
        defer if (final_source.ptr != source.ptr) alloc.free(final_source);
        const source_z = alloc.dupeZ(u8, final_source) catch |err| {
            stats.infra_error += 1;
            log("  INFRA-ERROR {s} ({s})\n", .{ full_path, @errorName(err) });
            continue;
        };
        defer alloc.free(source_z);

        const stage: zioshade.Stage = blk: {
            if (std.mem.endsWith(u8, full_path, ".vert") or std.mem.endsWith(u8, full_path, ".v.glsl"))
                break :blk .vertex
            else if (std.mem.endsWith(u8, full_path, ".comp") or std.mem.endsWith(u8, full_path, ".c.glsl"))
                break :blk .compute
            else if (std.mem.endsWith(u8, full_path, ".geom"))
                break :blk .geometry
            else if (std.mem.endsWith(u8, full_path, ".tesc"))
                break :blk .tessellation_control
            else if (std.mem.endsWith(u8, full_path, ".tese"))
                break :blk .tessellation_evaluation
            else if (std.mem.endsWith(u8, full_path, ".mesh"))
                break :blk .mesh
            else if (std.mem.endsWith(u8, full_path, ".task"))
                break :blk .task
            else if (std.mem.endsWith(u8, full_path, ".rgen"))
                break :blk .raygen
            else if (std.mem.endsWith(u8, full_path, ".rchit"))
                break :blk .closesthit
            else if (std.mem.endsWith(u8, full_path, ".rmiss"))
                break :blk .miss
            else if (std.mem.endsWith(u8, full_path, ".rahit"))
                break :blk .anyhit
            else if (std.mem.endsWith(u8, full_path, ".rint"))
                break :blk .intersection
            else if (std.mem.endsWith(u8, full_path, ".rcall"))
                break :blk .callable
            else
                break :blk .fragment;
        };

        const spirv_ver: zioshade.SPIRVVersion = if (stage == .mesh or stage == .task or
            stage == .raygen or stage == .closesthit or stage == .miss or
            stage == .intersection or stage == .anyhit or stage == .callable) .@"1.4" else .@"1.5";

        const compile_result = zioshade.compileToSPIRV(alloc, source_z, .{ .stage = stage, .spirv_version = spirv_ver });
        if (compile_result) |words| {
            alloc.free(words);
            if (isKnownUnsupported(full_path)) {
                // Unexpectedly passed — the KNOWN_UNSUPPORTED list is stale.
                stats.fail += 1;
                log("  UNEXPECTED-PASS {s} (was KNOWN_UNSUPPORTED — remove from list)\n", .{full_path});
            } else {
                stats.pass += 1;
            }
        } else |_| {
            if (isKnownUnsupported(full_path)) {
                stats.xfail += 1;
                log("  XFAIL {s}\n", .{full_path});
            } else {
                // A curated-valid fixture was rejected — false-positive regression!
                stats.fail += 1;
                log("  FP-REGRESSION {s} ctx={s} inner={s}\n", .{
                    full_path,
                    zioshade.lastErrorCtx() orelse "(none)",
                    zioshade.lastErrorInner() orelse "(none)",
                });
            }
        }
    }
}

/// Everything the command line can select. `min_pass` is the floor flag:
/// `--min-pass=N` (or `--min-pass N`) fails the run when fewer than N fixtures
/// passed. CI pins the current count so a silently shrinking corpus (renamed
/// directory, walker regression) cannot report success.
pub const Options = struct {
    save_spv_path: ?[]const u8 = null,
    target: ?[]const u8 = null,
    strict_enumerate: bool = false,
    strict_gate: bool = false,
    min_pass: ?u32 = null,
};

pub const ArgError = error{
    UnknownOption,
    MissingValue,
    InvalidNumber,
    UnexpectedPositional,
    ConflictingOptions,
};

/// Filled in on an `ArgError` so the caller can print which argument was bad.
pub const ArgDiag = struct {
    arg: []const u8 = "",
    detail: []const u8 = "",
};

/// Value of `--name=VALUE`, or null when `arg` is not that flag in `=` form.
fn inlineValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (arg.len <= name.len) return null;
    if (!std.mem.startsWith(u8, arg, name)) return null;
    if (arg[name.len] != '=') return null;
    return arg[name.len + 1 ..];
}

/// Accept both `--name=VALUE` and `--name VALUE`. Returns null when `argv[i.*]`
/// is some other flag, and advances `i` past the value in the separated form.
fn flagValue(
    argv: []const []const u8,
    i: *usize,
    name: []const u8,
    diag: *ArgDiag,
) ArgError!?[]const u8 {
    const arg = argv[i.*];
    if (inlineValue(arg, name)) |value| {
        if (value.len == 0) {
            diag.* = .{ .arg = arg, .detail = "expected a value after '='" };
            return error.MissingValue;
        }
        return value;
    }
    if (!std.mem.eql(u8, arg, name)) return null;
    if (i.* + 1 >= argv.len) {
        diag.* = .{ .arg = arg, .detail = "expected a value" };
        return error.MissingValue;
    }
    i.* += 1;
    return argv[i.*];
}

/// Parse the runner's command line. Pure (no I/O, no process exit) so the
/// self-tests can pin its behavior.
///
/// Every unrecognised argument beginning with '-' is an error. A silently
/// ignored option is exactly the failure this runner exists to rule out: a
/// mistyped `--minpass=2108` that fell through to the positional target would
/// leave the gate with no floor at all and still exit 0.
pub fn parseArgs(argv: []const []const u8, diag: *ArgDiag) ArgError!Options {
    var opts = Options{};

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "--strict-enumerate")) {
            opts.strict_enumerate = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict-gate")) {
            opts.strict_gate = true;
            continue;
        }
        if (try flagValue(argv, &i, "--save-spv", diag)) |value| {
            opts.save_spv_path = value;
            continue;
        }
        if (try flagValue(argv, &i, "--min-pass", diag)) |value| {
            opts.min_pass = std.fmt.parseInt(u32, value, 10) catch {
                diag.* = .{ .arg = value, .detail = "--min-pass expects a non-negative integer" };
                return error.InvalidNumber;
            };
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') {
            diag.* = .{ .arg = arg, .detail = "unrecognised option" };
            return error.UnknownOption;
        }
        if (opts.target != null) {
            diag.* = .{ .arg = arg, .detail = "a second positional target was given" };
            return error.UnexpectedPositional;
        }
        opts.target = arg;
    }

    // The gate modes walk every suite, so they ignore both the positional
    // target and --save-spv. Accepting them silently would hide a typo in the
    // one invocation that has to be trustworthy.
    if (opts.strict_gate or opts.strict_enumerate) {
        if (opts.target) |target| {
            diag.* = .{ .arg = target, .detail = "--strict-gate/--strict-enumerate walk every suite and ignore a target" };
            return error.UnexpectedPositional;
        }
        if (opts.save_spv_path) |path| {
            diag.* = .{ .arg = path, .detail = "--save-spv is ignored by --strict-gate/--strict-enumerate" };
            return error.UnexpectedPositional;
        }
    }

    // The two gate modes are mutually exclusive and the enumerate branch is
    // tested first, so accepting both would let the report silently win over
    // the gate the caller asked for.
    if (opts.strict_gate and opts.strict_enumerate) {
        diag.* = .{ .arg = "--strict-enumerate", .detail = "--strict-gate and --strict-enumerate are mutually exclusive" };
        return error.ConflictingOptions;
    }

    // --strict-enumerate is a report, not a gate: it has no pass count to
    // compare against a floor. Swallowing the flag here is the same
    // silent-ignore defect the floor exists to rule out.
    if (opts.strict_enumerate and opts.min_pass != null) {
        diag.* = .{ .arg = "--min-pass", .detail = "--strict-enumerate is a report and honors no pass floor" };
        return error.ConflictingOptions;
    }

    return opts;
}

// The entry point differs by Zig version: 0.16 hands command-line args and the
// environment in through a `std.process.Init.Minimal` parameter, while 0.15
// exposes them via the global `std.process.argsAlloc`. Select the matching
// signature at comptime (the same shape as src/cli.zig) so argument parsing
// works on both. It used to be skipped entirely on 0.16, which made the whole
// strict gate a silent no-op there: no --strict-gate, no --min-pass, exit 0.
pub const main = if (compat.is_0_16) main_0_16 else main_0_15;

fn main_0_15() !void {
    try mainImpl();
}

fn main_0_16(init: compat.MainInit) !void {
    compat.setMainInit(init);
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

    var stats = Stats{};

    // argsAlloc is version-shimmed in compat, so this runs identically on 0.15
    // and 0.16. The raw args stay alive for the whole run because target and
    // save_spv_path point into them.
    const raw_args = try compat.argsAlloc(alloc);
    defer compat.argsFree(alloc, raw_args);
    const argv = try alloc.alloc([]const u8, raw_args.len);
    defer alloc.free(argv);
    for (raw_args, 0..) |raw, idx| argv[idx] = raw;

    var diag = ArgDiag{};
    const opts = parseArgs(argv, &diag) catch |err| {
        log("ERROR: {s}: '{s}' ({s})\n", .{ @errorName(err), diag.arg, diag.detail });
        log("usage: conformance-runner [--strict-gate|--strict-enumerate] [--min-pass=N] [--save-spv PATH] [TARGET]\n", .{});
        std.process.exit(2);
    };
    const save_spv_path = opts.save_spv_path;
    const target_arg = opts.target;
    const strict_enumerate = opts.strict_enumerate;
    const strict_gate = opts.strict_gate;
    const min_pass = opts.min_pass;

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

    if (strict_gate) {
        log("\n=== STRICT-GATE: curated-valid fixtures must compile (no spirv-val) ===\n", .{});
        inline for (all_suites) |suite| {
            log("\n--- {s} ---\n", .{suite.@"0"});
            strictGateDir(io, alloc, suite.@"1", &stats) catch |err| {
                stats.infra_error += 1;
                log("  INFRA-ERROR suite {s} at {s} ({s})\n", .{ suite.@"0", suite.@"1", @errorName(err) });
            };
        }
        log("\n=== STRICT-GATE SUMMARY ===\n", .{});
        log("PASS:  {d}\n", .{stats.pass});
        log("XFAIL: {d}\n", .{stats.xfail});
        log("FAIL (FP-regression): {d}\n", .{stats.fail});
        log("INFRA_ERROR: {d}\n", .{stats.infra_error});
        log("TOTAL: {d}\n", .{stats.total()});
        if (stats.fail > 0) {
            log("ERROR: {} curated-valid fixture(s) were rejected, false-positive regressions!\n", .{stats.fail});
        }
        reportExitReasons(stats, min_pass);
        if (shouldFail(stats, min_pass)) std.process.exit(1);
        return;
    }

    if (target_arg) |target| {
        var matched_suite = false;
        inline for (all_suites) |suite| {
            if (std.mem.eql(u8, target, suite.@"0")) {
                log("\n=== {s} ===\n", .{suite.@"0"});
                runDir(io, alloc, suite.@"1", &stats) catch |err| {
                    stats.infra_error += 1;
                    log("  INFRA-ERROR suite {s} at {s} ({s})\n", .{ suite.@"0", suite.@"1", @errorName(err) });
                };
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
                const result = testShader(io, alloc, target, save_spv_path) catch |err| blk: {
                    log("  INFRA-ERROR {s} ({s})\n", .{ target, @errorName(err) });
                    break :blk Result.infra_error;
                };
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
                    .infra_error => {
                        stats.infra_error += 1;
                        log("  INFRA-ERROR {s} (harness I/O failure)\n", .{target});
                    },
                }
            } else {
                log("\n=== {s} ===\n", .{target});
                runDir(io, alloc, target, &stats) catch |err| {
                    stats.infra_error += 1;
                    log("  INFRA-ERROR {s} ({s})\n", .{ target, @errorName(err) });
                };
            }
        }
    } else {
        inline for (all_suites) |suite| {
            log("\n=== {s} ===\n", .{suite.@"0"});
            runDir(io, alloc, suite.@"1", &stats) catch |err| {
                stats.infra_error += 1;
                log("  INFRA-ERROR suite {s} at {s} ({s})\n", .{ suite.@"0", suite.@"1", @errorName(err) });
            };
        }
    }

    log("\n=== SUMMARY ===\n", .{});
    log("PASS:           {d}\n", .{stats.pass});
    log("FAIL (spirv):   {d}\n", .{stats.fail});
    log("FAIL (compile): {d}\n", .{stats.compile_error});
    log("SKIP:           {d}\n", .{stats.skip});
    log("XFAIL:          {d}\n", .{stats.xfail});
    log("INFRA_ERROR:    {d}\n", .{stats.infra_error});
    log("TOTAL:          {d}\n", .{stats.total()});

    reportExitReasons(stats, min_pass);
    if (shouldFail(stats, min_pass)) {
        std.process.exit(1);
    }
}
