const std = @import("std");
const glslpp = @import("glslpp");

test "hlsl mesh: emits OutputTopology and mesh<> signature" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x=1) in;
        \\layout(triangles, max_vertices=3, max_primitives=1) out;
        \\layout(location=0) out vec4 v_color[];
        \\void main() { SetMeshOutputsEXT(3, 1); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .mesh });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"triangle\")]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "out vertices") != null);
    // Negative guard: must not also emit other topologies.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"line\")]") == null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"point\")]") == null);
}

test "hlsl mesh: lines topology emits [OutputTopology(\"line\")]" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x=1) in;
        \\layout(lines, max_vertices=2, max_primitives=1) out;
        \\layout(location=0) out vec4 v_color[];
        \\void main() { SetMeshOutputsEXT(2, 1); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .mesh });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"line\")]") != null);
    // Negative guard: must not also emit other topologies.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"triangle\")]") == null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"point\")]") == null);
}

test "hlsl mesh: points topology emits [OutputTopology(\"point\")]" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x=1) in;
        \\layout(points, max_vertices=1, max_primitives=1) out;
        \\layout(location=0) out vec4 v_color[];
        \\void main() { SetMeshOutputsEXT(1, 1); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .mesh });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"point\")]") != null);
    // Negative guard: must not also emit other topologies.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"triangle\")]") == null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"line\")]") == null);
}
