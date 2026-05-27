const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

// M5.2 v3 — mesh shader BODY codegen tests.
//
// The HLSL "v2" work assumed semantic/codegen actually emit OpStore
// instructions for each per-vertex / per-primitive output write.  Prior to v3
// it didn't: `gl_MeshVerticesEXT` wasn't even registered as a global, so the
// first `gl_MeshVerticesEXT[0].gl_Position = ...` errored inside
// `analyzeLValue`. With `tolerate_errors = true` (the public compile path),
// the error was swallowed and the rest of the function body was discarded —
// silently producing a SPIR-V module whose `main` only contained
// `OpSetMeshOutputsEXT` + `OpReturn`.
//
// These tests guard the contract that the mesh shader body actually reaches
// SPIR-V as OpStore instructions for each user-visible output.

fn countOpStores(spirv: []const u32) usize {
    var count: usize = 0;
    var i: usize = 5; // skip header
    while (i < spirv.len) {
        const word = spirv[i];
        const opcode = word & 0xFFFF;
        const word_count = word >> 16;
        if (word_count == 0) break; // malformed; bail
        if (opcode == @intFromEnum(glslpp.spirv.Op.Store)) count += 1;
        i += word_count;
    }
    return count;
}

fn hasOpcode(spirv: []const u32, target: u32) bool {
    var i: usize = 5;
    while (i < spirv.len) {
        const word = spirv[i];
        const opcode = word & 0xFFFF;
        const word_count = word >> 16;
        if (word_count == 0) break;
        if (opcode == target) return true;
        i += word_count;
    }
    return false;
}

test "mesh shader emits OpStore for per-vertex, per-primitive and user-location outputs" {
    const source =
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
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{
        .stage = .mesh,
        .spirv_version = .@"1.4",
    });
    defer alloc.free(spirv);

    // We expect at least 5 OpStores: 3 gl_Position, 1 v_color, 1 indices.
    const stores = countOpStores(spirv);
    try std.testing.expect(stores >= 5);
}

test "mesh shader user per-vertex output arrays are sized (no OpTypeRuntimeArray)" {
    // `out vec4 v_color[]` in a mesh shader needs to be a sized array of
    // length `max_vertices`. OpTypeRuntimeArray fails Vulkan validation:
    //   VUID-StandaloneSpirv-OpTypeRuntimeArray-04680 — OpTypeRuntimeArray
    //   may only appear as the final member of an OpTypeStruct.
    const source =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x=1) in;
        \\layout(triangles, max_vertices=3, max_primitives=1) out;
        \\layout(location=0) out vec4 v_color[];
        \\void main() {
        \\    SetMeshOutputsEXT(3, 1);
        \\    v_color[0] = vec4(1.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{
        .stage = .mesh,
        .spirv_version = .@"1.4",
    });
    defer alloc.free(spirv);

    // OpTypeRuntimeArray = 30, OpTypeArray = 28
    try std.testing.expect(!hasOpcode(spirv, @intFromEnum(glslpp.spirv.Op.TypeRuntimeArray)));
    try std.testing.expect(hasOpcode(spirv, @intFromEnum(glslpp.spirv.Op.TypeArray)));
}
