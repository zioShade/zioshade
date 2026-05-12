const std = @import("std");
pub const glslpp = @import("glslpp");
const compat = glslpp.compat;

pub fn main(maybe_init: compat.MainInit) !void {
    compat.setMainInit(maybe_init);
    var gpa_impl = compat.Gpa(.{}){};
    defer _ = gpa_impl.deinit();
    const alloc = gpa_impl.allocator();

    var main_io = compat.MainIo().init(alloc);
    defer main_io.deinit();
    const io = main_io.io();

    const args = try compat.argsAlloc(alloc);
    defer compat.argsFree(alloc, args);

    if (args.len < 4) {
        std.debug.print("Usage: glsl_cross <input.glsl> <output_prefix> <target:hlsl|glsl|msl>\n", .{});
        return;
    }

    const input_path = args[1];
    const output_prefix = args[2];
    const target = args[3];

    // Read input GLSL
    const dir = compat.cwd();
    const glsl_src = try compat.dirReadFileAlloc(io, dir, alloc, input_path, 1024 * 1024);
    defer alloc.free(glsl_src);

    // Add null terminator
    var src_buf = try alloc.allocSentinel(u8, glsl_src.len, 0);
    defer alloc.free(src_buf);
    @memcpy(src_buf[0..glsl_src.len], glsl_src);

    // Compile to SPIR-V
    const spv = try glslpp.compileToSPIRV(alloc, src_buf, .{ .stage = .fragment });
    defer alloc.free(spv);

    // Cross-compile to target
    var output: []const u8 = undefined;
    if (std.mem.eql(u8, target, "hlsl")) {
        output = try glslpp.spirvToHLSL(alloc, spv, .{ .shader_model = 60 });
    } else if (std.mem.eql(u8, target, "glsl")) {
        output = try glslpp.spirvToGLSL(alloc, spv, .{});
    } else if (std.mem.eql(u8, target, "msl")) {
        output = try glslpp.spirvToMSL(alloc, spv, .{});
    } else {
        std.debug.print("Unknown target: {s}\n", .{target});
        return;
    }
    defer alloc.free(output);

    // Write output
    var out_path: [512]u8 = undefined;
    const out_name = try std.fmt.bufPrint(&out_path, "{s}_glslpp.{s}", .{ output_prefix, target });
    try compat.dirWriteFile(io, dir, out_name, output);
    std.debug.print("Wrote {s}\n", .{out_name});
}
