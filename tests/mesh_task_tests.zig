const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

test "minimal mesh shader compiles to SPIR-V" {
    const source =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x = 32) in;
        \\layout(triangles, max_vertices = 64, max_primitives = 126) out;
        \\void main() {
        \\    SetMeshOutputsEXT(3, 1);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .mesh, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    try std.testing.expect(spirv.len > 0);
    // Verify SPIR-V header
    try std.testing.expectEqual(@as(u32, 0x07230203), spirv[0]); // magic
}
