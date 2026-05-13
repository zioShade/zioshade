const std = @import("std");
const glslpp = @import("glslpp");

/// SPIR-V to HLSL cross-compiler CLI.
/// Usage: zig build spv-to-hlsl -- <input.spv> <output.hlsl>
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 3) {
        std.debug.print("Usage: spv_to_hlsl <input.spv> <output.hlsl>\n", .{});
        return;
    }

    const input_path = args[1];
    const output_path = args[2];

    // Read SPIR-V binary
    const spv_bytes = std.fs.cwd().readFileAlloc(alloc, input_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ input_path, err });
        return;
    };
    defer alloc.free(spv_bytes);

    if (spv_bytes.len < 4 or spv_bytes.len % 4 != 0) {
        std.debug.print("Invalid SPIR-V binary: {d} bytes\n", .{spv_bytes.len});
        return;
    }

    // Copy to aligned buffer
    const spirv_words = try alloc.alloc(u32, spv_bytes.len / 4);
    defer alloc.free(spirv_words);
    @memcpy(std.mem.sliceAsBytes(spirv_words), spv_bytes);

    // Cross-compile to HLSL
    const hlsl = glslpp.spirvToHLSL(alloc, spirv_words, .{ .shader_model = 60 }) catch |err| {
        std.debug.print("Error cross-compiling to HLSL: {}\n", .{err});
        return;
    };
    defer alloc.free(hlsl);

    // Write output
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(hlsl);
}
