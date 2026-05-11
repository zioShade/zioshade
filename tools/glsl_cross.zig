const std = @import("std");
pub const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 4) {
        std.debug.print("Usage: glsl_cross <input.glsl> <output_prefix> <target:hlsl|glsl|msl>\n", .{});
        return;
    }

    const input_path = args[1];
    const output_prefix = args[2];
    const target = args[3];

    // Read input GLSL
    const cwd = std.fs.cwd();
    const glsl_src = try cwd.readFileAlloc(alloc, input_path, 1024 * 1024);
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
    try cwd.writeFile(.{ .sub_path = out_name, .data = output });
    std.debug.print("Wrote {s}\n", .{out_name});
}
