const std = @import("std");
const glslpp = @import("glslpp");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

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

    const iterations = 50;

    // Warmup
    {
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
        defer alloc.free(spirv);
        const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
        defer alloc.free(hlsl);
    }

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var hlsl_size: usize = 0;
    var spirv_size: usize = 0;

    for (0..iterations) |_| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
        defer alloc.free(spirv);
        const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
        defer alloc.free(hlsl);
        const end = std.Io.Clock.Timestamp.now(io, .awake);

        const dur = start.durationTo(end);
        const elapsed: u64 = @intCast(dur.raw.nanoseconds);
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
        spirv_size = spirv.len;
        hlsl_size = hlsl.len;
    }

    const avg_us = @divFloor(total_ns, iterations * 1000);
    const min_us = @divFloor(min_ns, 1000);
    const max_us = @divFloor(max_ns, 1000);

    std.debug.print("glslpp benchmark ({d} iterations, ReleaseFast)\n", .{iterations});
    std.debug.print("  Avg total: {d} us\n", .{avg_us});
    std.debug.print("  Min total: {d} us\n", .{min_us});
    std.debug.print("  Max total: {d} us\n", .{max_us});
    std.debug.print("  SPIR-V words: {d}\n", .{spirv_size});
    std.debug.print("  HLSL bytes:   {d}\n", .{hlsl_size});
}
