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

// ---------------------------------------------------------------------------
// M5.2 v2 — VertexOut/PrimOut struct aggregation.
// ---------------------------------------------------------------------------

test "hlsl mesh v2: VertexOut struct emitted with SV_Position and user vars" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x=1) in;
        \\layout(triangles, max_vertices=3, max_primitives=1) out;
        \\layout(location=0) out vec4 v_color[];
        \\void main() {
        \\    SetMeshOutputsEXT(3, 1);
        \\    gl_MeshVerticesEXT[0].gl_Position = vec4(0.0);
        \\    v_color[0] = vec4(1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .mesh });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);
    // VertexOut struct exists with gl_Position : SV_Position
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "struct VertexOut") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SV_Position") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "v_color") != null);
    // Signature uses VertexOut, not float4
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "out vertices VertexOut") != null);
}

test "hlsl mesh v2: perprimitiveEXT emits PrimOut struct" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x=1) in;
        \\layout(triangles, max_vertices=3, max_primitives=1) out;
        \\layout(location=0) out vec4 v_color[];
        \\layout(location=1) perprimitiveEXT out vec3 face_normal[];
        \\void main() { SetMeshOutputsEXT(3, 1); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .mesh });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "struct PrimOut") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "out primitives PrimOut") != null);
}

test "hlsl mesh v2: no PrimOut when no perprimitiveEXT outputs" {
    // Negative-control: a mesh shader without any per-primitive outputs must
    // not emit `struct PrimOut` or the `out primitives` signature parameter.
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
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "struct PrimOut") == null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "out primitives") == null);
}

// ---------------------------------------------------------------------------
// M5.2 v2.c — body store routing for mesh outputs.
//
// After v2.b emitted VertexOut/PrimOut struct shapes, the body still wrote
// bare `gl_MeshPerVertexEXT[i]`, `v_color[i]`, and
// `gl_PrimitiveTriangleIndicesEXT[i]` — none of which are HLSL identifiers
// in scope inside the mesh entry point. v2.c routes those stores through
// the signature parameters: `verts[i].gl_Position`, `verts[i].v_color`,
// and `prims[i]` (note: indices array is flat, not `prims[i].member`).
// ---------------------------------------------------------------------------

test "hlsl mesh v2.c: per-vertex stores route through verts[i].field" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x=1) in;
        \\layout(triangles, max_vertices=3, max_primitives=1) out;
        \\layout(location=0) out vec4 v_color[];
        \\void main() {
        \\    SetMeshOutputsEXT(3, 1);
        \\    gl_MeshVerticesEXT[0].gl_Position = vec4(0.0, 1.0, 0.0, 1.0);
        \\    gl_MeshVerticesEXT[1].gl_Position = vec4(-1.0, -1.0, 0.0, 1.0);
        \\    gl_MeshVerticesEXT[2].gl_Position = vec4(1.0, -1.0, 0.0, 1.0);
        \\    v_color[0] = vec4(1.0, 0.0, 0.0, 1.0);
        \\    gl_PrimitiveTriangleIndicesEXT[0] = uvec3(0, 1, 2);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .mesh });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);

    // Positive: stores must be routed through the signature parameters.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "verts[0].gl_Position") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "verts[1].gl_Position") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "verts[2].gl_Position") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "verts[0].v_color") != null);
    // Indices array is a flat uint3[] — `prims[i]`, not `prims[i].field`.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "prims[0] = ") != null);

    // Negative: the bare/undeclared names must not appear as l-values.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "gl_MeshPerVertexEXT[") == null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "gl_PrimitiveTriangleIndicesEXT[") == null);
    // `v_color[` would be the un-routed write — DXC rejects it; make sure
    // we don't emit it as an l-value or r-value in the body.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "v_color[") == null);
}

test "hlsl mesh v2.c: VertexOut struct omits gl_MeshPerVertexEXT and indices fields" {
    // VertexOut already carries `gl_Position : SV_Position` as its seed field,
    // so the synthetic `gl_MeshPerVertexEXT` array element doesn't need its
    // own user field — it would duplicate the position. The triangle/line/
    // point indices array is also not a per-vertex output: it's the
    // `out indices uint3 prims[]` signature parameter. Neither belongs in
    // the VertexOut struct.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x=1) in;
        \\layout(triangles, max_vertices=3, max_primitives=1) out;
        \\layout(location=0) out vec4 v_color[];
        \\void main() {
        \\    SetMeshOutputsEXT(3, 1);
        \\    gl_MeshVerticesEXT[0].gl_Position = vec4(0.0);
        \\    v_color[0] = vec4(1.0);
        \\    gl_PrimitiveTriangleIndicesEXT[0] = uvec3(0, 1, 2);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .mesh });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);

    // Locate the VertexOut struct body and assert these fields are absent.
    const struct_start = std.mem.indexOf(u8, hlsl, "struct VertexOut") orelse return error.TestUnexpectedResult;
    const struct_end = std.mem.indexOfPos(u8, hlsl, struct_start, "};") orelse return error.TestUnexpectedResult;
    const struct_body = hlsl[struct_start..struct_end];

    try std.testing.expect(std.mem.indexOf(u8, struct_body, "gl_MeshPerVertexEXT") == null);
    try std.testing.expect(std.mem.indexOf(u8, struct_body, "gl_PrimitiveTriangleIndicesEXT") == null);
    // v_color is a legitimate user per-vertex output and must remain.
    try std.testing.expect(std.mem.indexOf(u8, struct_body, "v_color") != null);
}
