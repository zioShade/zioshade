//! Minimal GLSL → SPIR-V → HLSL pipeline.
//! Build with: `zig run examples/glsl_to_hlsl.zig --mod zioshade::src/root.zig --deps zioshade`

const std = @import("std");
const zioshade = @import("zioshade");

const SOURCE =
    \\#version 430
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 0) out vec4 fragColor;
    \\layout(binding = 0) uniform Globals {
    \\    float u_time;
    \\    vec2  u_resolution;
    \\} g;
    \\void main() {
    \\    vec2 p = uv * 2.0 - 1.0;
    \\    fragColor = vec4(0.5 + 0.5 * cos(g.u_time + p.xyx + vec3(0, 2, 4)), 1.0);
    \\}
;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // GLSL → SPIR-V
    const spirv = try zioshade.compileToSPIRV(alloc, SOURCE, .{
        .stage = .fragment,
        .version = 430,
    });
    defer alloc.free(spirv);

    std.debug.print("SPIR-V: {d} words ({d} bytes)\n", .{ spirv.len, spirv.len * 4 });

    // SPIR-V → HLSL
    const hlsl = try zioshade.spirvToHLSL(alloc, spirv, .{
        .binding_shift = -1,
        .shader_model = 60,
    });
    defer alloc.free(hlsl);

    std.debug.print("\n--- HLSL ---\n{s}\n", .{hlsl});
}
