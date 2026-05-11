const std = @import("std");
const glslpp = @import("glslpp");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    // Read files at runtime to avoid package path restrictions
    const prefix = try cwd.readFileAlloc(io, "tests/wintty/shadertoy_prefix.glsl", alloc, .limited(1024 * 1024));
    defer alloc.free(prefix);

    const crt = try cwd.readFileAlloc(io, "tests/wintty/test_crt.glsl", alloc, .limited(1024 * 1024));
    defer alloc.free(crt);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, prefix);
    try buf.appendSlice(alloc, "\n\n");
    try buf.appendSlice(alloc, crt);
    try buf.append(alloc, 0);
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    std.debug.print("SPIR-V: {d} words\n", .{spirv.len});

    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
    defer alloc.free(hlsl);
    try cwd.writeFile(io, .{ .sub_path = "tests/wintty/crt_output.hlsl", .data = hlsl });
    std.debug.print("HLSL: {d} bytes\n", .{hlsl.len});

    const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 });
    defer alloc.free(glsl);
    try cwd.writeFile(io, .{ .sub_path = "tests/wintty/crt_output.glsl", .data = glsl });
    std.debug.print("GLSL: {d} bytes\n", .{glsl.len});

    const msl = try glslpp.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try cwd.writeFile(io, .{ .sub_path = "tests/wintty/crt_output.msl", .data = msl });
    std.debug.print("MSL: {d} bytes\n", .{msl.len});
}
