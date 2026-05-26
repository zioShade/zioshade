//! Compile a fragment shader and enumerate its uniforms.
//! Build with: `zig run examples/reflect_uniforms.zig --mod glslpp::src/root.zig --deps glslpp`

const std = @import("std");
const glslpp = @import("glslpp");

const SOURCE =
    \\#version 430
    \\layout(binding = 0) uniform Camera {
    \\    mat4 view;
    \\    mat4 proj;
    \\} cam;
    \\layout(binding = 1) uniform Material {
    \\    vec4 albedo;
    \\    float roughness;
    \\} mat;
    \\layout(binding = 2) uniform sampler2D albedoTex;
    \\layout(location = 0) in vec2 uv;
    \\layout(location = 0) out vec4 fragColor;
    \\void main() {
    \\    vec4 c = texture(albedoTex, uv) * mat.albedo;
    \\    fragColor = cam.proj[0] * c;
    \\}
;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const spirv = try glslpp.compileToSPIRV(alloc, SOURCE, .{
        .stage = .fragment,
        .version = 430,
    });
    defer alloc.free(spirv);

    var resources = try glslpp.reflectSPIRV(alloc, spirv);
    defer resources.deinit(alloc);

    std.debug.print("Uniform buffers ({d}):\n", .{resources.uniform_buffers.len});
    for (resources.uniform_buffers) |ubo| {
        std.debug.print("  set={d} binding={d}  {s}\n", .{ ubo.set, ubo.binding, ubo.name });
    }

    std.debug.print("\nSampled images ({d}):\n", .{resources.sampled_images.len});
    for (resources.sampled_images) |s| {
        std.debug.print("  set={d} binding={d}  {s}\n", .{ s.set, s.binding, s.name });
    }
}
