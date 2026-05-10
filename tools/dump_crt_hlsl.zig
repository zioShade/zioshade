const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Read files at runtime (not embed) to avoid package path restrictions
    const prefix_file = try std.fs.cwd().openFile("tests/wintty/shadertoy_prefix.glsl", .{});
    defer prefix_file.close();
    const prefix = try prefix_file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(prefix);

    const crt_file = try std.fs.cwd().openFile("tests/wintty/test_crt.glsl", .{});
    defer crt_file.close();
    const crt = try crt_file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(crt);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, prefix);
    try buf.appendSlice(alloc, "\n\n");
    try buf.appendSlice(alloc, crt);
    try buf.append(alloc, 0);
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{
        .binding_shift = -1,
        .shader_model = 60,
    });
    defer alloc.free(hlsl);

    const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 });
    defer alloc.free(glsl);

    const msl = try glslpp.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);

    const out_file = try std.fs.cwd().createFile("tests/wintty/crt_output.hlsl", .{});
    defer out_file.close();
    try out_file.writeAll(hlsl);
    std.debug.print("HLSL output: {d} bytes, {d} SPIR-V words\n", .{ hlsl.len, spirv.len });

    const glsl_file = try std.fs.cwd().createFile("tests/wintty/crt_output.glsl", .{});
    defer glsl_file.close();
    try glsl_file.writeAll(glsl);
    std.debug.print("GLSL output: {d} bytes\n", .{glsl.len});

    const msl_file = try std.fs.cwd().createFile("tests/wintty/crt_output.msl", .{});
    defer msl_file.close();
    try msl_file.writeAll(msl);
    std.debug.print("MSL output: {d} bytes\n", .{msl.len});
    std.debug.print("Saved to tests/wintty/crt_output.hlsl\n", .{});
}
