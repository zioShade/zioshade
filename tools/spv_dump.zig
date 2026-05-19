const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 3) {
        std.debug.print("Usage: spv_dump <input.glsl> <output.spv>\n", .{});
        return;
    }

    const raw = try std.fs.cwd().readFileAlloc(alloc, args[1], 1024 * 1024);
    defer alloc.free(raw);
    const input: [:0]const u8 = try alloc.dupeZ(u8, raw);
    defer alloc.free(input);

    const spv = try glslpp.compileToSPIRV(alloc, input, .{ .stage = .compute });
    defer alloc.free(spv);

    const bytes = std.mem.sliceAsBytes(spv);
    const file = try std.fs.cwd().createFile(args[2], .{});
    try file.writeAll(bytes);
    file.close();
    std.debug.print("Wrote {} words ({} bytes) to {s}\n", .{ spv.len, bytes.len, args[2] });
}
