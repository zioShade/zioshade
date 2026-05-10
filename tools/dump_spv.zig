const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 3) {
        std.debug.print("Usage: dump_spv <input.glsl> <output.spv>\n", .{});
        return;
    }

    const source_file = try std.fs.cwd().openFile(args[1], .{});
    defer source_file.close();
    const source_raw = try source_file.readToEndAlloc(alloc, 10 * 1024 * 1024);
    defer alloc.free(source_raw);

    // Null-terminate
    var buf: std.ArrayListUnmanaged(u8) = .{};
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
    const spv_file = try std.fs.cwd().createFile(args[2], .{});
    defer spv_file.close();
    try spv_file.writeAll(std.mem.sliceAsBytes(spirv_words));
    std.debug.print("SPIR-V: {d} words ({d} bytes)\n", .{ spirv_words.len, spirv_words.len * 4 });
}
