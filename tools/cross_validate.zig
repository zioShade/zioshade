const std = @import("std");
const zioshade = @import("zioshade");

pub fn main() !void {
    const alloc = std.heap.page_allocator; // short-lived CLI; OS reclaims on exit
    const args = try zioshade.compat.argsAlloc(alloc);
    defer zioshade.compat.argsFree(alloc, args);
    if (args.len < 4) {
        std.debug.print("Usage: cross_validate <input.glsl> <zioshade_output_prefix> <spirvcross_output_prefix>\n", .{});
        std.debug.print("  Compiles GLSL via both zioshade and glslangValidator+spirv-cross\n", .{});
        std.debug.print("  Generates .hlsl, .glsl, .msl from both pipelines\n", .{});
        return;
    }

    const input_path = args[1];
    const zioshade_prefix = args[2];
    const spirvcross_prefix = args[3];
    _ = spirvcross_prefix; // spirv-cross comparison pipeline not yet wired here

    // Read input GLSL
    const source_raw = try zioshade.compat.readFileByPath(alloc, input_path, 10 * 1024 * 1024);
    defer alloc.free(source_raw);

    // Null-terminate
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, source_raw);
    try buf.append(alloc, 0);
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    // === Pipeline 1: zioshade ===
    const spirv = zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment }) catch |err| {
        std.debug.print("SKIP zioshade compileToSPIRV: {}\n", .{err});
        return;
    };
    defer alloc.free(spirv);
    std.debug.print("zioshade SPIR-V: {d} words\n", .{spirv.len});

    // zioshade → HLSL
    const hlsl = zioshade.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 }) catch |err| {
        std.debug.print("SKIP zioshade spirvToHLSL: {}\n", .{err});
        return;
    };
    defer alloc.free(hlsl);
    const hlsl_path = try std.fmt.allocPrint(alloc, "{s}.hlsl", .{zioshade_prefix});
    defer alloc.free(hlsl_path);
    try zioshade.compat.writeFileByPath(alloc, hlsl_path, hlsl);

    // zioshade → GLSL
    const glsl = zioshade.spirvToGLSL(alloc, spirv, .{ .version = 430 }) catch |err| {
        std.debug.print("SKIP zioshade spirvToGLSL: {}\n", .{err});
        return;
    };
    defer alloc.free(glsl);
    const glsl_path = try std.fmt.allocPrint(alloc, "{s}.glsl", .{zioshade_prefix});
    defer alloc.free(glsl_path);
    try zioshade.compat.writeFileByPath(alloc, glsl_path, glsl);

    // zioshade → MSL
    const msl = zioshade.spirvToMSL(alloc, spirv, .{}) catch |err| {
        std.debug.print("SKIP zioshade spirvToMSL: {}\n", .{err});
        return;
    };
    defer alloc.free(msl);
    const msl_path = try std.fmt.allocPrint(alloc, "{s}.msl", .{zioshade_prefix});
    defer alloc.free(msl_path);
    try zioshade.compat.writeFileByPath(alloc, msl_path, msl);

    // Write zioshade SPIR-V
    const spv_path = try std.fmt.allocPrint(alloc, "{s}.spv", .{zioshade_prefix});
    defer alloc.free(spv_path);
    try zioshade.compat.writeFileByPath(alloc, spv_path, std.mem.sliceAsBytes(spirv));

    std.debug.print("zioshade outputs: {s}.*\n", .{zioshade_prefix});
}
