const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    // Short-lived generator: compileToSPIRV intentionally leaks internal state
    // (see tests/runner.zig), so a leak-checking GPA would spam stderr on every
    // run. Use the page allocator and let the OS reclaim memory on exit.
    const alloc = std.heap.page_allocator;

    const cwd = std.fs.cwd();

    // Read files at runtime to avoid package path restrictions
    const prefix = try cwd.readFileAlloc(alloc, "tests/wintty/shadertoy_prefix.glsl", 1024 * 1024);
    defer alloc.free(prefix);

    const crt = try cwd.readFileAlloc(alloc, "tests/wintty/test_crt.glsl", 1024 * 1024);
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
    try cwd.writeFile(.{ .sub_path = "tests/wintty/crt_output.hlsl", .data = hlsl });
    std.debug.print("HLSL: {d} bytes\n", .{hlsl.len});

    const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 });
    defer alloc.free(glsl);
    try cwd.writeFile(.{ .sub_path = "tests/wintty/crt_output.glsl", .data = glsl });
    std.debug.print("GLSL: {d} bytes\n", .{glsl.len});

    const msl = try glslpp.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try cwd.writeFile(.{ .sub_path = "tests/wintty/crt_output.msl", .data = msl });
    std.debug.print("MSL: {d} bytes\n", .{msl.len});
}
