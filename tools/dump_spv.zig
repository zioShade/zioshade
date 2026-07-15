const std = @import("std");
const zioshade = @import("zioshade");

pub fn main() !void {
    const alloc = std.heap.page_allocator; // short-lived CLI; OS reclaims on exit
    const args = try zioshade.compat.argsAlloc(alloc);
    defer zioshade.compat.argsFree(alloc, args);
    if (args.len < 3) {
        std.debug.print("Usage: dump_spv <input.glsl> <output.spv>\n", .{});
        return;
    }

    const source_raw = try zioshade.compat.readFileByPath(alloc, args[1], 10 * 1024 * 1024);
    defer alloc.free(source_raw);

    // Null-terminate
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, source_raw);
    try buf.append(alloc, 0);
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    // Compile GLSL → SPIR-V
    const spirv_words = zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment }) catch |err| {
        std.debug.print("Compilation error: {}\n", .{err});
        return err;
    };
    defer alloc.free(spirv_words);

    // Write SPIR-V binary
    try zioshade.compat.writeFileByPath(alloc, args[2], std.mem.sliceAsBytes(spirv_words));
    std.debug.print("SPIR-V: {d} words ({d} bytes)\n", .{ spirv_words.len, spirv_words.len * 4 });
}
