const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Usage: test_unopt_wgsl <dir>\n", .{});
        return;
    }

    const dir_path = args[1];
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var total: u32 = 0;
    var ok: u32 = 0;
    var fail: u32 = 0;
    var skip: u32 = 0;
    var fail_list = std.ArrayList([]const u8).initCapacity(alloc, 32) catch return error.OutOfMemory;
    defer fail_list.deinit(alloc);

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = entry.path;
        if (!std.mem.endsWith(u8, path, ".frag") and !std.mem.endsWith(u8, path, ".vert") and !std.mem.endsWith(u8, path, ".comp") and !std.mem.endsWith(u8, path, ".geom")) continue;

        total += 1;

        const file = try dir.openFile(path, .{});
        defer file.close();
        const source_raw = try file.readToEndAlloc(alloc, 1024 * 1024);
        defer alloc.free(source_raw);
        const source = try alloc.dupeZ(u8, source_raw);
        defer alloc.free(source);

        const stage: glslpp.Stage = if (std.mem.endsWith(u8, path, ".vert"))
            .vertex
        else if (std.mem.endsWith(u8, path, ".comp"))
            .compute
        else
            .fragment;

        // Compile WITHOUT optimization
        const spv_result = glslpp.compileToSPIRVNoOpt(alloc, source, .{ .stage = stage });
        if (spv_result) |spv| {
            const wgsl_result = glslpp.spirvToWGSL(alloc, spv, .{});
            if (wgsl_result) |wgsl| {
                alloc.free(wgsl);
                ok += 1;
            } else |err| {
                fail += 1;
                const path_copy = try alloc.dupe(u8, path);
                try fail_list.append(alloc, path_copy);
                if (fail <= 20) {
                    std.debug.print("  WGSL FAIL (unopt): {s} ({any})\n", .{ path, err });
                }
            }
            alloc.free(spv);
        } else |_| {
            skip += 1;
        }
    }

    std.debug.print("\n=== Unoptimized SPIR-V → WGSL ===\n", .{});
    std.debug.print("Total:   {d}\n", .{total});
    std.debug.print("OK:      {d}\n", .{ok});
    std.debug.print("FAIL:    {d}\n", .{fail});
    std.debug.print("SKIP:    {d} (compile fail)\n", .{skip});
}
