const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    const source =
        \#version 430
        \layout(binding = 0) uniform isampler2D tex;
        \layout(location = 0) out ivec4 fragColor;
        \void main() {
        \    ivec4 c = texelFetch(tex, ivec2(0, 0), 0);
        \    fragColor = c;
        \}
    ;
    const spirv = try glslpp.compileToSPIRV(std.testing.allocator, source, .{ .stage = .fragment });
    defer std.testing.allocator.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(std.testing.allocator, spirv, .{ .binding_shift = -1, .shader_model = 60 });
    defer std.testing.allocator.free(hlsl);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{hlsl});
}
