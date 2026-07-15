const std = @import("std");
const zioshade = @import("zioshade");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try zioshade.compat.argsAlloc(alloc);
    defer zioshade.compat.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Usage: test_wgsl_coverage <dir>\n", .{});
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

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = entry.path;
        if (!std.mem.endsWith(u8, path, ".frag") and !std.mem.endsWith(u8, path, ".vert") and !std.mem.endsWith(u8, path, ".comp") and !std.mem.endsWith(u8, path, ".geom") and !std.mem.endsWith(u8, path, ".tese") and !std.mem.endsWith(u8, path, ".tesc")) continue;

        total += 1;

        const file = try dir.openFile(path, .{});
        defer file.close();
        const source_raw = try file.readToEndAlloc(alloc, 1024 * 1024);
        defer alloc.free(source_raw);
        const source = try alloc.dupeZ(u8, source_raw);
        defer alloc.free(source);

        const stage: zioshade.Stage = if (std.mem.endsWith(u8, path, ".vert"))
            .vertex
        else if (std.mem.endsWith(u8, path, ".comp"))
            .compute
        else if (std.mem.endsWith(u8, path, ".geom"))
            .geometry
        else if (std.mem.endsWith(u8, path, ".tesc"))
            .tessellation_control
        else if (std.mem.endsWith(u8, path, ".tese"))
            .tessellation_evaluation
        else
            .fragment;

        const spv_result = zioshade.compileToSPIRV(alloc, source, .{ .stage = stage });
        if (spv_result) |spv| {
            const wgsl_result = zioshade.spirvToWGSL(alloc, spv, .{});
            if (wgsl_result) |wgsl| {
                alloc.free(wgsl);
                ok += 1;
            } else |err| {
                fail += 1;
                if (fail <= 30) {
                    std.debug.print("  WGSL FAIL: {s} ({any})\n", .{ path, err });
                }
            }
            alloc.free(spv);
        } else |_| {
            skip += 1;
        }
    }

    std.debug.print("\n=== WGSL Coverage ===\n", .{});
    std.debug.print("Total:   {d}\n", .{total});
    std.debug.print("OK:      {d}\n", .{ok});
    std.debug.print("FAIL:    {d}\n", .{fail});
    std.debug.print("SKIP:    {d} (compile fail)\n", .{skip});
}
