const std = @import("std");
const glslpp = @import("glslpp");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        std.process.fatal("unable to parse args: {}", .{err});
    };
    if (args.len < 3) {
        std.debug.print("Usage: dump_spv <input.glsl> <output.spv>\n", .{});
        return;
    }

    const source_raw = try cwd.readFileAlloc(io, args[1], alloc, .limited(10 * 1024 * 1024));
    defer alloc.free(source_raw);

    // Null-terminate
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, source_raw);
    try buf.append(alloc, 0);
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    // Compile GLSL → SPIR-V
    const spirv_words = glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment }) catch |err| {
        std.debug.print("Compilation error: {}\n", .{err});
        return err;
    };
    defer alloc.free(spirv_words);

    // Write SPIR-V binary
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = std.mem.sliceAsBytes(spirv_words) });
    std.debug.print("SPIR-V: {d} words ({d} bytes)\n", .{ spirv_words.len, spirv_words.len * 4 });
}
