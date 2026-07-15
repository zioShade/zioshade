const std = @import("std");
const zioshade = @import("zioshade");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try zioshade.compat.argsAlloc(alloc);
    defer zioshade.compat.argsFree(alloc, args);
    if (args.len < 3) {
        std.debug.print("Usage: spv_dump <input.glsl> <output.spv>\n", .{});
        return;
    }

    const raw = try zioshade.compat.readFileByPath(alloc, args[1], 1024 * 1024);
    defer alloc.free(raw);
    const input: [:0]const u8 = try alloc.dupeZ(u8, raw);
    defer alloc.free(input);

    const stage: zioshade.Stage = if (std.mem.endsWith(u8, args[1], ".comp")) .compute else if (std.mem.endsWith(u8, args[1], ".vert")) .vertex else if (std.mem.endsWith(u8, args[1], ".geom")) .geometry else if (std.mem.endsWith(u8, args[1], ".tesc")) .tessellation_control else if (std.mem.endsWith(u8, args[1], ".tese")) .tessellation_evaluation else .fragment;
    const result = zioshade.compileToSPIRV(alloc, input, .{ .stage = stage });
    const spv = result catch |err| {
        std.debug.print("Compile error: {}\n", .{err});
        if (zioshade.last_compile_detail) |d| {
            std.debug.print("Detail: {s}\n", .{@tagName(d)});
        }
        return err;
    };
    defer alloc.free(spv);

    const bytes = std.mem.sliceAsBytes(spv);
    try zioshade.compat.writeFileByPath(alloc, args[2], bytes);
    std.debug.print("Wrote {} words ({} bytes) to {s}\n", .{ spv.len, bytes.len, args[2] });
}
