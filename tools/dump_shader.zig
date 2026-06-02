const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    const alloc = std.heap.page_allocator; // short-lived CLI; OS reclaims on exit
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 4) {
        std.debug.print("Usage: dump_shader <prefix.glsl> <shader.glsl> <output_prefix>\n", .{});
        std.debug.print("  Generates <output_prefix>.hlsl, .glsl, .msl, .spv\n", .{});
        return;
    }
    const out_prefix = args[3];

    const prefix = try std.fs.cwd().readFileAlloc(alloc, args[1], 1024 * 1024);
    defer alloc.free(prefix);

    const shader = try std.fs.cwd().readFileAlloc(alloc, args[2], 1024 * 1024);
    defer alloc.free(shader);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, prefix);
    try buf.appendSlice(alloc, "\n\n");
    try buf.appendSlice(alloc, shader);
    try buf.append(alloc, 0);
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    std.debug.print("SPIR-V: {d} words ({d} bytes)\n", .{ spirv.len, spirv.len * 4 });

    // Write SPIR-V binary
    const spv_path = try std.fmt.allocPrint(alloc, "{s}.spv", .{out_prefix});
    defer alloc.free(spv_path);
    try std.fs.cwd().writeFile(.{ .sub_path = spv_path, .data = std.mem.sliceAsBytes(spirv) });

    // Generate and write HLSL
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
    defer alloc.free(hlsl);
    const hlsl_path = try std.fmt.allocPrint(alloc, "{s}.hlsl", .{out_prefix});
    defer alloc.free(hlsl_path);
    try std.fs.cwd().writeFile(.{ .sub_path = hlsl_path, .data = hlsl });
    std.debug.print("HLSL: {d} bytes -> {s}\n", .{ hlsl.len, hlsl_path });

    // Generate and write GLSL
    const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 });
    defer alloc.free(glsl);
    const glsl_path = try std.fmt.allocPrint(alloc, "{s}.glsl", .{out_prefix});
    defer alloc.free(glsl_path);
    try std.fs.cwd().writeFile(.{ .sub_path = glsl_path, .data = glsl });
    std.debug.print("GLSL: {d} bytes -> {s}\n", .{ glsl.len, glsl_path });

    // Generate and write MSL
    const msl = try glslpp.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    const msl_path = try std.fmt.allocPrint(alloc, "{s}.msl", .{out_prefix});
    defer alloc.free(msl_path);
    try std.fs.cwd().writeFile(.{ .sub_path = msl_path, .data = msl });
    std.debug.print("MSL: {d} bytes -> {s}\n", .{ msl.len, msl_path });
}
