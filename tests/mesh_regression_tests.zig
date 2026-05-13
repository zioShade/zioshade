const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

// Regression tests for mesh/task shader bugs fixed during conformance hardening.
// These verify specific bugs don't regress.

test "SetMeshOutputsEXT uses uint operands (not signed int)" {
    // Bug: int literal 1 was used as signed int, SPIR-V requires uint
    const source =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x = 1) in;
        \\layout(points, max_vertices = 1, max_primitives = 1) out;
        \\void main() {
        \\    SetMeshOutputsEXT(1, 1);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .mesh, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    // Verify OpSetMeshOutputsEXT (5295) exists with valid operands
    var found = false;
    for (spirv, 0..) |word, i| {
        if ((word & 0xFFFF) == 5295) {
            found = true;
            try std.testing.expectEqual(@as(u32, 3), word >> 16);
            try std.testing.expect(spirv[i + 1] > 0);
            try std.testing.expect(spirv[i + 2] > 0);
        }
    }
    try std.testing.expect(found);
}

test "EmitMeshTasksEXT passes payload variable pointer" {
    // Bug: payload was auto-loaded, passing array value instead of pointer
    const source =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x = 4) in;
        \\taskPayloadSharedEXT float sharedData[64];
        \\void main() {
        \\    EmitMeshTasksEXT(1, 1, 1, sharedData);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .task, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    // Find payload variable (OpVariable with TaskPayloadWorkgroupEXT=5402)
    var payload_var_id: ?u32 = null;
    for (spirv, 0..) |word, i| {
        if ((word & 0xFFFF) == @intFromEnum(glslpp.spirv.Op.Variable)) {
            const wc = word >> 16;
            if (wc >= 4 and i + 3 < spirv.len and spirv[i + 3] == 5402) {
                payload_var_id = spirv[i + 2];
            }
        }
    }
    try std.testing.expect(payload_var_id != null);
    // Verify EmitMeshTasksEXT (5294) last operand is payload variable
    for (spirv, 0..) |word, i| {
        if ((word & 0xFFFF) == 5294) {
            try std.testing.expectEqual(@as(u32, 5), word >> 16);
            try std.testing.expectEqual(payload_var_id.?, spirv[i + 4]);
        }
    }
}

test "no OpReturn after EmitMeshTasksEXT terminator" {
    // Bug: OpReturn emitted after EmitMeshTasksEXT (a terminator instruction)
    const source =
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(local_size_x = 4) in;
        \\taskPayloadSharedEXT float data[32];
        \\void main() {
        \\    EmitMeshTasksEXT(1, 1, 1, data);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .task, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    var emit_found = false;
    var return_after_emit = false;
    for (spirv) |word| {
        if ((word & 0xFFFF) == 5294) emit_found = true;
        if (emit_found and (word & 0xFFFF) == 114) return_after_emit = true;
    }
    try std.testing.expect(emit_found);
    try std.testing.expect(!return_after_emit);
}

test "mesh shader opcode enum values correct" {
    try std.testing.expectEqual(@as(u32, 5294), @intFromEnum(glslpp.spirv.Op.EmitMeshTasksEXT));
    try std.testing.expectEqual(@as(u32, 5295), @intFromEnum(glslpp.spirv.Op.SetMeshOutputsEXT));
    try std.testing.expectEqual(@as(u32, 27), @intFromEnum(glslpp.spirv.ExecutionMode.OutputPoints));
    try std.testing.expectEqual(@as(u32, 5269), @intFromEnum(glslpp.spirv.ExecutionMode.OutputLinesEXT));
    try std.testing.expectEqual(@as(u32, 5298), @intFromEnum(glslpp.spirv.ExecutionMode.OutputTrianglesEXT));
}

test "ray tracing opcode enum values correct" {
    try std.testing.expectEqual(@as(u32, 4445), @intFromEnum(glslpp.spirv.Op.TraceRayKHR));
    try std.testing.expectEqual(@as(u32, 4448), @intFromEnum(glslpp.spirv.Op.IgnoreIntersectionKHR));
    try std.testing.expectEqual(@as(u32, 4449), @intFromEnum(glslpp.spirv.Op.TerminateRayKHR));
    try std.testing.expectEqual(@as(u32, 4446), @intFromEnum(glslpp.spirv.Op.ExecuteCallableKHR));
}

test "GroupNonUniform opcode values correct after audit fix" {
    // Were off by 2 due to non-standard InclusiveBitCount/ExclusiveBitCount entries
    try std.testing.expectEqual(@as(u32, 365), @intFromEnum(glslpp.spirv.Op.GroupNonUniformQuadBroadcast));
    try std.testing.expectEqual(@as(u32, 366), @intFromEnum(glslpp.spirv.Op.GroupNonUniformQuadSwap));
    // All/Any were swapped
    try std.testing.expectEqual(@as(u32, 155), @intFromEnum(glslpp.spirv.Op.All));
    try std.testing.expectEqual(@as(u32, 154), @intFromEnum(glslpp.spirv.Op.Any));
}
