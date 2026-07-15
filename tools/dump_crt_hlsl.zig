const std = @import("std");
const zioshade = @import("zioshade");

pub fn main() !void {
    // Short-lived generator: compileToSPIRV intentionally leaks internal state
    // (see tests/runner.zig), so a leak-checking GPA would spam stderr on every
    // run. Use the page allocator and let the OS reclaim memory on exit.
    const alloc = std.heap.page_allocator;

    // Read files at runtime to avoid package path restrictions
    const prefix = try zioshade.compat.readFileByPath(alloc, "tests/wintty/shadertoy_prefix.glsl", 1024 * 1024);
    defer alloc.free(prefix);

    const crt = try zioshade.compat.readFileByPath(alloc, "tests/wintty/test_crt.glsl", 1024 * 1024);
    defer alloc.free(crt);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, prefix);
    try buf.appendSlice(alloc, "\n\n");
    try buf.appendSlice(alloc, crt);
    try buf.append(alloc, 0);
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    std.debug.print("SPIR-V: {d} words\n", .{spirv.len});

    const hlsl = try zioshade.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
    defer alloc.free(hlsl);
    try zioshade.compat.writeFileByPath(alloc, "tests/wintty/crt_output.hlsl", hlsl);
    std.debug.print("HLSL: {d} bytes\n", .{hlsl.len});

    const glsl = try zioshade.spirvToGLSL(alloc, spirv, .{ .version = 430 });
    defer alloc.free(glsl);
    try zioshade.compat.writeFileByPath(alloc, "tests/wintty/crt_output.glsl", glsl);
    std.debug.print("GLSL: {d} bytes\n", .{glsl.len});

    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try zioshade.compat.writeFileByPath(alloc, "tests/wintty/crt_output.msl", msl);
    std.debug.print("MSL: {d} bytes\n", .{msl.len});
}
