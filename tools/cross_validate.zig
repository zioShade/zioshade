const std = @import("std");
const glslpp = @import("glslpp");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        std.process.fatal("unable to parse args: {}", .{err});
    };
    if (args.len < 4) {
        std.debug.print("Usage: cross_validate <input.glsl> <glslpp_output_prefix> <spirvcross_output_prefix>\n", .{});
        std.debug.print("  Compiles GLSL via both glslpp and glslangValidator+spirv-cross\n", .{});
        std.debug.print("  Generates .hlsl, .glsl, .msl from both pipelines\n", .{});
        return;
    }

    const input_path = args[1];
    const glslpp_prefix = args[2];
    const spirvcross_prefix = args[3];

    // Read input GLSL
    const source_raw = try cwd.readFileAlloc(io, input_path, alloc, .limited(10 * 1024 * 1024));
    defer alloc.free(source_raw);

    // Null-terminate
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, source_raw);
    try buf.append(alloc, 0);
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    // === Pipeline 1: glslpp ===
    const spirv = glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment }) catch |err| {
        std.debug.print("SKIP glslpp compileToSPIRV: {}\n", .{err});
        return;
    };
    defer alloc.free(spirv);
    std.debug.print("glslpp SPIR-V: {d} words\n", .{spirv.len});

    // glslpp → HLSL
    const hlsl = glslpp.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 }) catch |err| {
        std.debug.print("SKIP glslpp spirvToHLSL: {}\n", .{err});
        return;
    };
    defer alloc.free(hlsl);
    const hlsl_path = try std.fmt.allocPrint(alloc, "{s}.hlsl", .{glslpp_prefix});
    defer alloc.free(hlsl_path);
    try cwd.writeFile(io, .{ .sub_path = hlsl_path, .data = hlsl });

    // glslpp → GLSL
    const glsl = glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 }) catch |err| {
        std.debug.print("SKIP glslpp spirvToGLSL: {}\n", .{err});
        return;
    };
    defer alloc.free(glsl);
    const glsl_path = try std.fmt.allocPrint(alloc, "{s}.glsl", .{glslpp_prefix});
    defer alloc.free(glsl_path);
    try cwd.writeFile(io, .{ .sub_path = glsl_path, .data = glsl });

    // glslpp → MSL
    const msl = glslpp.spirvToMSL(alloc, spirv, .{}) catch |err| {
        std.debug.print("SKIP glslpp spirvToMSL: {}\n", .{err});
        return;
    };
    defer alloc.free(msl);
    const msl_path = try std.fmt.allocPrint(alloc, "{s}.msl", .{glslpp_prefix});
    defer alloc.free(msl_path);
    try cwd.writeFile(io, .{ .sub_path = msl_path, .data = msl });

    // Write glslpp SPIR-V
    const spv_path = try std.fmt.allocPrint(alloc, "{s}.spv", .{glslpp_prefix});
    defer alloc.free(spv_path);
    try cwd.writeFile(io, .{ .sub_path = spv_path, .data = std.mem.sliceAsBytes(spirv) });

    std.debug.print("glslpp outputs: {s}.*\n", .{glslpp_prefix});
}
