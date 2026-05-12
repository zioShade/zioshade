const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

// ============================================================================
// Ray Tracing Pipeline Tests
// ============================================================================

test "raygen shader compiles to SPIR-V" {
    const source =
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(local_size_x = 1) in;
        \\void main() {
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .raygen, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    try std.testing.expect(spirv.len > 0);
    try std.testing.expectEqual(@as(u32, 0x07230203), spirv[0]); // magic
}

test "miss shader compiles to SPIR-V" {
    const source =
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(local_size_x = 1) in;
        \\void main() {
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .miss, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    try std.testing.expect(spirv.len > 0);
}

test "closesthit shader compiles to SPIR-V" {
    const source =
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(local_size_x = 1) in;
        \\hitAttributeEXT vec2 bary;
        \\void main() {
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .closesthit, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    try std.testing.expect(spirv.len > 0);
}

test "raygen with builtin variables" {
    const source =
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(local_size_x = 1) in;
        \\void main() {
        \\    uvec3 lid = gl_LaunchIDEXT;
        \\    uvec3 ls = gl_LaunchSizeEXT;
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .raygen, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    try std.testing.expect(spirv.len > 0);
}

test "raygen shader cross-compiles to HLSL" {
    const source =
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(local_size_x = 1) in;
        \\void main() {
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .raygen, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[shader(\"raygeneration\")]") != null);
}

test "closesthit shader cross-compiles to HLSL" {
    const source =
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(local_size_x = 1) in;
        \\hitAttributeEXT vec2 bary;
        \\void main() {
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .closesthit, .spirv_version = .@"1.4" });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[shader(\"closesthit\")]") != null);
}

test "ray tracing stages fail GLSL cross-compilation" {
    const source =
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(local_size_x = 1) in;
        \\void main() {}
    ;
    inline for (.{
        .raygen,
        .closesthit,
        .miss,
        .intersection,
        .anyhit,
        .callable,
    }) |stage| {
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = stage, .spirv_version = .@"1.4" });
        defer alloc.free(spirv);
        const result = glslpp.spirvToGLSL(alloc, spirv, .{});
        try std.testing.expectError(error.CrossCompileUnsupported, result);
    }
}

test "ray tracing stages fail MSL cross-compilation" {
    const source =
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(local_size_x = 1) in;
        \\void main() {}
    ;
    inline for (.{
        .raygen,
        .closesthit,
        .miss,
        .intersection,
        .anyhit,
        .callable,
    }) |stage| {
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = stage, .spirv_version = .@"1.4" });
        defer alloc.free(spirv);
        const result = glslpp.spirvToMSL(alloc, spirv, .{});
        try std.testing.expectError(error.CrossCompileUnsupported, result);
    }
}

test "raygen requires SPIR-V 1.4+" {
    const source =
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(local_size_x = 1) in;
    ;
    const result = glslpp.compileToSPIRV(alloc, source, .{ .stage = .raygen, .spirv_version = .@"1.3" });
    try std.testing.expectError(error.CodegenFailed, result);
}
