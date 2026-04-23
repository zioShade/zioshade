const std = @import("std");
const glslpp = @import("src/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const source = "#version 430\nvoid main() {\n    float x = 1.0;\n    float y = x * 2.0 + 3.0;\n}";

    const words = try glslpp.compileToSPIRV(alloc, source, .{});
    defer alloc.free(words);

    const tmp_dir = try std.fs.cwd().makeOpenPath(".zig-cache", .{});
    const file = try tmp_dir.createFile("test_validate.spv", .{ .truncate = true });
    defer file.close();
    const bytes = std.mem.sliceAsBytes(words);
    try file.writeAll(bytes);

    std.debug.print("Generated {d} SPIR-V words ({d} bytes)\n", .{ words.len, bytes.len });

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "spirv-val", ".zig-cache/test_validate.spv" },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    std.debug.print("spirv-val exit code: {d}\n", .{result.term.Exited});
    if (result.stderr.len > 0) {
        std.debug.print("stderr: {s}\n", .{result.stderr});
    }
}
