
const std = @import("std");
const zioshade = @import("zioshade");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const args = try zioshade.compat.argsAlloc(alloc);
    defer zioshade.compat.argsFree(alloc, args);
    if (args.len < 3) return;
    const raw = try zioshade.compat.readFileByPath(alloc, args[1], 1024 * 1024);
    defer alloc.free(raw);
    const input: [:0]const u8 = try alloc.dupeZ(u8, raw);
    defer alloc.free(input);
    const stage: zioshade.Stage = if (std.mem.endsWith(u8, args[1], ".vert")) .vertex else .fragment;
    const spv = try zioshade.compileToSPIRVNoOpt(alloc, input, .{ .stage = stage });
    defer alloc.free(spv);
    try zioshade.compat.writeFileByPath(alloc, args[2], std.mem.sliceAsBytes(spv));
    std.debug.print("Wrote {} words\n", .{spv.len});
}
