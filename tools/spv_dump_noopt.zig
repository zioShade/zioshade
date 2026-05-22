
const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 3) return;
    const raw = try std.fs.cwd().readFileAlloc(alloc, args[1], 1024 * 1024);
    defer alloc.free(raw);
    const input: [:0]const u8 = try alloc.dupeZ(u8, raw);
    defer alloc.free(input);
    const stage: glslpp.Stage = if (std.mem.endsWith(u8, args[1], ".vert")) .vertex else .fragment;
    const spv = try glslpp.compileToSPIRVNoOpt(alloc, input, .{ .stage = stage });
    defer alloc.free(spv);
    const file = try std.fs.cwd().createFile(args[2], .{});
    try file.writeAll(std.mem.sliceAsBytes(spv));
    file.close();
    std.debug.print("Wrote {} words\n", .{spv.len});
}
