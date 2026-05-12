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
    try std.testing.expectEqual(@as(u32, 0x07230203), spirv[0]); // magic
}

test "mesh shader cross-compiles to HLSL" {
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
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[numthreads(32, 1, 1)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SetMeshOutputCounts(3, 1)") != null);
}
