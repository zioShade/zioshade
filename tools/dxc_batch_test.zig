const std = @import("std");
const glslpp = @import("glslpp");

/// SPIR-V execution model → stage classification.
const SpvStage = enum {
    vertex,
    fragment,
    compute,
    mesh,
    task,
    raygen,
    intersection,
    anyhit,
    closesthit,
    miss,
    callable,
    geometry,
    tess_control,
    tess_eval,
    unknown,

    fn name(self: SpvStage) []const u8 {
        return @tagName(self);
    }
};

/// Read the first `OpEntryPoint` (opcode 15) in a SPIR-V module and
/// return its execution model as an `SpvStage`. Returns `.unknown` if
/// no entry point is found or the module is malformed.
fn detectStage(spv: []const u32) SpvStage {
    if (spv.len < 5) return .unknown;
    // Skip the 5-word SPIR-V header.
    var i: usize = 5;
    while (i < spv.len) {
        const word = spv[i];
        const wc: usize = word >> 16;
        const op: u16 = @intCast(word & 0xFFFF);
        if (wc == 0) break;
        if (op == 15 and wc >= 3) {
            // OpEntryPoint: word[1] = execution model.
            return switch (spv[i + 1]) {
                0 => .vertex,
                1 => .tess_control,
                2 => .tess_eval,
                3 => .geometry,
                4 => .fragment,
                5 => .compute,
                5267 => .task, // TaskNV (legacy)
                5268 => .mesh, // MeshNV (legacy)
                5364 => .task, // TaskEXT (GL_EXT_mesh_shader)
                5365 => .mesh, // MeshEXT (GL_EXT_mesh_shader)
                5313 => .raygen,
                5314 => .intersection,
                5315 => .anyhit,
                5316 => .closesthit,
                5317 => .miss,
                5318 => .callable,
                else => .unknown,
            };
        }
        i += wc;
    }
    return .unknown;
}

/// Return the DXC target profile (e.g. "ps_6_0") for a given stage and
/// shader-model. Stages glslpp does not yet emit valid HLSL for return
/// null, which the driver treats as a SKIP. Caller owns the returned
/// buffer and must free it via the supplied allocator.
fn dxcProfile(alloc: std.mem.Allocator, stage: SpvStage, sm: u32) !?[]u8 {
    const major = sm / 10;
    const minor = sm % 10;
    return switch (stage) {
        .fragment => try std.fmt.allocPrint(alloc, "ps_{d}_{d}", .{ major, minor }),
        .compute => try std.fmt.allocPrint(alloc, "cs_{d}_{d}", .{ major, minor }),
        // Mesh & amplification shaders require Shader Model 6.5+. Skip with
        // null when caller passed an older SM so the driver classifies it
        // (clearly) instead of returning a bogus profile string.
        .mesh => if (sm < 65) null else try std.fmt.allocPrint(alloc, "ms_{d}_{d}", .{ major, minor }),
        .task => if (sm < 65) null else try std.fmt.allocPrint(alloc, "as_{d}_{d}", .{ major, minor }),
        // M5.0 (vertex signature emission) shipped, so vertex maps to vs_*.
        .vertex => try std.fmt.allocPrint(alloc, "vs_{d}_{d}", .{ major, minor }),
        // Stages we know glslpp doesn't yet emit valid HLSL for. They are
        // tracked as deferred roadmap items (M5.2 v2 mesh)
        // or simply unimplemented (raytracing, geometry, tess).
        .geometry,
        .tess_control,
        .tess_eval,
        .raygen,
        .intersection,
        .anyhit,
        .closesthit,
        .miss,
        .callable,
        .unknown,
        => null,
    };
}

fn skipReason(stage: SpvStage) []const u8 {
    return switch (stage) {
        .vertex => "vertex stage — shipped (should never SKIP)",
        .mesh => "mesh stage — needs SM 6.5+ (pass -- <dxc> <dir> 65)",
        .task => "task stage — not yet implemented",
        .geometry => "geometry stage — not yet implemented",
        .tess_control, .tess_eval => "tessellation stage — not yet implemented",
        .raygen, .intersection, .anyhit, .closesthit, .miss, .callable => "ray-tracing stage — not yet implemented",
        .unknown => "unknown execution model",
        .fragment, .compute => unreachable, // never SKIPped, always run
        // .vertex handled above
    };
}

const StageBucket = struct {
    pass: u32 = 0,
    fail: u32 = 0,
    skip: u32 = 0,
};

const STAGE_LIST = [_]SpvStage{
    .fragment,
    .compute,
    .vertex,
    .mesh,
    .task,
    .geometry,
    .tess_control,
    .tess_eval,
    .raygen,
    .intersection,
    .anyhit,
    .closesthit,
    .miss,
    .callable,
    .unknown,
};

/// Pull the first `error:` line from DXC's stderr and trim it to ~80
/// chars; this is the bucket key for the top-failures histogram.
fn firstErrorKey(alloc: std.mem.Allocator, stderr_str: []const u8) ![]u8 {
    var slice: []const u8 = stderr_str;
    if (std.mem.indexOf(u8, stderr_str, "error:")) |idx| {
        slice = stderr_str[idx..];
    }
    // Trim to first newline.
    if (std.mem.indexOfScalar(u8, slice, '\n')) |nl| {
        slice = slice[0..nl];
    }
    // Trim to first 80 chars.
    const trimmed = slice[0..@min(slice.len, 80)];
    return alloc.dupe(u8, std.mem.trimEnd(u8, trimmed, " \r\t"));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const dxc_path = if (args.len > 1) args[1] else "C:/VulkanSDK/1.4.341.1/Bin/dxc.exe";
    const spv_dir = if (args.len > 2) args[2] else "tests/spirv_bins";
    const sm: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 60;

    var dir = try std.fs.cwd().openDir(spv_dir, .{ .iterate = true });
    defer dir.close();

    // Per-stage tallies.
    var buckets = std.AutoArrayHashMap(SpvStage, StageBucket).init(alloc);
    defer buckets.deinit();
    for (STAGE_LIST) |s| try buckets.put(s, .{});

    // Top-failures histogram (error-line → count). The keys are owned by
    // this map; we free them at teardown.
    var fail_hist = std.StringHashMap(u32).init(alloc);
    defer {
        var it = fail_hist.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        fail_hist.deinit();
    }

    var total_pass: u32 = 0;
    var total_fail: u32 = 0;
    var total_skip: u32 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".spv")) continue;

        // Read SPIR-V binary.
        const spv_data = dir.readFileAlloc(alloc, name, 1024 * 1024) catch |err| {
            std.debug.print("SKIP {s}: read error {}\n", .{ name, err });
            total_skip += 1;
            const b = buckets.getPtr(.unknown).?;
            b.skip += 1;
            continue;
        };
        defer alloc.free(spv_data);
        const spv_u32_len = spv_data.len / 4;
        const spv = @as([*]const u32, @ptrCast(@alignCast(spv_data.ptr)))[0..spv_u32_len];

        const stage = detectStage(spv);
        const bucket = buckets.getPtr(stage).?;

        const profile_opt = try dxcProfile(alloc, stage, sm);
        if (profile_opt == null) {
            std.debug.print("SKIP {s} ({s}): {s}\n", .{ name, stage.name(), skipReason(stage) });
            bucket.skip += 1;
            total_skip += 1;
            continue;
        }
        const profile = profile_opt.?;
        defer alloc.free(profile);

        // Convert to HLSL.
        const hlsl = glslpp.spirvToHLSL(alloc, spv, .{ .shader_model = sm }) catch |err| {
            std.debug.print("FAIL {s} ({s}): cross-compile error {}\n", .{ name, stage.name(), err });
            bucket.fail += 1;
            total_fail += 1;
            const key = try std.fmt.allocPrint(alloc, "glslpp cross-compile error: {}", .{err});
            // Insert or increment.
            const gop = try fail_hist.getOrPut(key);
            if (gop.found_existing) {
                alloc.free(key);
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
            continue;
        };
        defer alloc.free(hlsl);

        // Write HLSL to a temp file (one shared name; fine because we run sequentially).
        const tmp_path = "tmp_hlsl_test.hlsl";
        {
            const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
            defer tmp_file.close();
            try tmp_file.writeAll(hlsl);
        }
        defer std.fs.cwd().deleteFile(tmp_path) catch {};

        // Run DXC with the resolved profile.
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ dxc_path, "-T", profile, "-E", "main", tmp_path },
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);

        const exited_ok = switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        };

        if (exited_ok) {
            bucket.pass += 1;
            total_pass += 1;
            std.debug.print("PASS {s} ({s} → {s})\n", .{ name, stage.name(), profile });
        } else {
            bucket.fail += 1;
            total_fail += 1;
            const key = try firstErrorKey(alloc, result.stderr);
            const gop = try fail_hist.getOrPut(key);
            if (gop.found_existing) {
                alloc.free(key);
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
            std.debug.print("FAIL {s} ({s} → {s}): {s}\n", .{ name, stage.name(), profile, gop.key_ptr.* });
        }
    }

    // Per-stage summary.
    std.debug.print("\n=== DXC Validation Summary (SM {d}.{d}) ===\n", .{ sm / 10, sm % 10 });
    for (STAGE_LIST) |s| {
        const b = buckets.get(s) orelse continue;
        if (b.pass == 0 and b.fail == 0 and b.skip == 0) continue;
        const suffix: []const u8 = switch (s) {
            .vertex => "",
            .mesh => "  (signature + body routing OK — M5.2 v2.c)",
            .task => "  (not implemented)",
            .geometry, .tess_control, .tess_eval => "  (not implemented)",
            .raygen, .intersection, .anyhit, .closesthit, .miss, .callable => "  (not implemented)",
            else => "",
        };
        std.debug.print(
            "{s:<14}: {d:>3} PASS / {d:>3} FAIL / {d:>3} SKIP{s}\n",
            .{ s.name(), b.pass, b.fail, b.skip, suffix },
        );
    }
    std.debug.print("\nTotal: {d} PASS / {d} FAIL / {d} SKIP\n", .{ total_pass, total_fail, total_skip });

    // Top-N failures histogram. Sort by count descending.
    if (fail_hist.count() > 0) {
        const SortEntry = struct {
            key: []const u8,
            count: u32,
            fn lessThan(_: void, a: @This(), b: @This()) bool {
                return a.count > b.count;
            }
        };
        var entries = std.ArrayList(SortEntry).empty;
        defer entries.deinit(alloc);
        var it = fail_hist.iterator();
        while (it.next()) |e| try entries.append(alloc, .{ .key = e.key_ptr.*, .count = e.value_ptr.* });
        std.mem.sort(SortEntry, entries.items, {}, SortEntry.lessThan);

        std.debug.print("\nTop {d} FAIL reasons:\n", .{@min(entries.items.len, 5)});
        const limit = @min(entries.items.len, 5);
        for (entries.items[0..limit], 0..) |e, i| {
            std.debug.print("  {d}. \"{s}\": {d} occurrence(s)\n", .{ i + 1, e.key, e.count });
        }
    }

    // Sanity check: if we processed any fragment shaders and none passed,
    // something is very wrong — exit non-zero so CI catches it. Otherwise
    // the tool exits 0 even with failures (per-fixture failures are
    // tracked via the printed summary, not the exit code).
    const frag = buckets.get(.fragment) orelse StageBucket{};
    if ((frag.pass + frag.fail) > 0 and frag.pass == 0) {
        std.debug.print("\nERROR: zero fragment shaders passed — likely a regression.\n", .{});
        std.process.exit(1);
    }
}
