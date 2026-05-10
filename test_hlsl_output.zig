const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const source =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() {
        \\    vec4 c = texture(tex, uv);
        \\    float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));
        \\    if (lum > 0.5) {
        \\        fragColor = c;
        \\    } else {
        \\        fragColor = vec4(0.0);
        \\    }
        \\}
    ;
    const hlsl = try glslpp.compileGlslToHlsl(alloc, source, .fragment);
    defer alloc.free(hlsl);
    const stdout = std.io.tty.getStdoutWriter();
    try stdout.print("{s}\n", .{hlsl});
}
