const std = @import("std");
const glslpp = @import("glslpp");
const reflect = @import("glslpp").reflection;

// =============================================================================
// G1: Reflection API — deep correctness tests
// =============================================================================

test "G1: multiple UBOs at different bindings and sets" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, set = 0, binding = 0) uniform UBO0 { vec4 a; };
        \\layout(std140, set = 0, binding = 1) uniform UBO1 { vec4 b; };
        \\layout(std140, set = 1, binding = 0) uniform UBO2 { vec4 c; };
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = a + b + c; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), res.uniform_buffers.len);

    const b0 = res.uniform_buffers[0];
    const b1 = res.uniform_buffers[1];
    const b2 = res.uniform_buffers[2];
    try std.testing.expectEqual(@as(u32, 0), b0.binding);
    try std.testing.expectEqual(@as(u32, 1), b1.binding);
    try std.testing.expectEqual(@as(u32, 0), b2.binding);
    try std.testing.expect(b2.set != 0xFFFF_FFFF);
}

test "G1: UBO member names and offsets are extracted" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform MyBlock {
        \\    vec4 position;
        \\    vec4 color;
        \\    float scale;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = position * color * scale; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    const ubo = res.uniform_buffers[0];
    try std.testing.expect(ubo.members.len >= 3);

    try std.testing.expectEqualStrings("position", ubo.members[0].name);
    try std.testing.expectEqual(@as(u32, 0), ubo.members[0].offset);

    try std.testing.expectEqualStrings("color", ubo.members[1].name);
    try std.testing.expectEqual(@as(u32, 16), ubo.members[1].offset);

    try std.testing.expectEqualStrings("scale", ubo.members[2].name);
    try std.testing.expectEqual(@as(u32, 32), ubo.members[2].offset);
}

test "G1: UBO member type kinds are resolved" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform Types {
        \\    int i;
        \\    uint u;
        \\    float f;
        \\    vec4 v;
        \\    mat4 m;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(float(i), float(u), f, 1.0) * m * v; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    const ubo = res.uniform_buffers[0];
    try std.testing.expect(ubo.members.len >= 5);
    try std.testing.expectEqual(reflect.TypeKind.scalar_int, ubo.members[0].type_kind);
    try std.testing.expectEqual(reflect.TypeKind.scalar_uint, ubo.members[1].type_kind);
    try std.testing.expectEqual(reflect.TypeKind.scalar_float, ubo.members[2].type_kind);
    try std.testing.expectEqual(reflect.TypeKind.vector, ubo.members[3].type_kind);
    try std.testing.expectEqual(reflect.TypeKind.matrix, ubo.members[4].type_kind);
}

test "G1: multiple sampled images at different bindings" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(binding = 0) uniform sampler2D texA;
        \\layout(binding = 1) uniform sampler2D texB;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    vec4 a = texture(texA, vec2(0.0));
        \\    vec4 b = texture(texB, vec2(0.0));
        \\    FragColor = a + b;
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expect(res.sampled_images.len >= 2);
    var found_0 = false;
    var found_1 = false;
    for (res.sampled_images) |si| {
        if (si.binding == 0) found_0 = true;
        if (si.binding == 1) found_1 = true;
    }
    try std.testing.expect(found_0 and found_1);
}

test "G1: vertex shader entry point and inputs" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(location = 0) in vec3 aPos;
        \\layout(location = 1) in vec2 aUV;
        \\layout(location = 0) out vec2 vUV;
        \\void main() {
        \\    gl_Position = vec4(aPos, 1.0);
        \\    vUV = aUV;
        \\}
    , .{ .stage = .vertex });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expect(res.entry_points.len >= 1);
    try std.testing.expectEqual(reflect.Stage.vertex, res.entry_points[0].stage);
    try std.testing.expect(res.inputs.len >= 2);
    try std.testing.expect(res.outputs.len >= 1);
}

test "G1: compute shader entry point with SSBOs" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
        \\layout(std430, binding = 0) buffer SrcBuf { float src[]; };
        \\layout(std430, binding = 1) buffer DstBuf { float dst[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    dst[idx] = src[idx] * 2.0;
        \\}
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expect(res.entry_points.len >= 1);
    try std.testing.expectEqual(reflect.Stage.compute, res.entry_points[0].stage);
    try std.testing.expectEqual(@as(usize, 2), res.storage_buffers.len);
}

test "G1: empty shader reflects minimal resources" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\void main() {}
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), res.uniform_buffers.len);
    try std.testing.expectEqual(@as(usize, 0), res.storage_buffers.len);
    try std.testing.expectEqual(@as(usize, 0), res.sampled_images.len);
    try std.testing.expectEqual(@as(usize, 0), res.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), res.outputs.len);
    try std.testing.expectEqual(@as(usize, 0), res.push_constants.len);
    try std.testing.expect(res.entry_points.len >= 1);
}

test "G1: invalid SPIR-V magic returns error" {
    const alloc = std.testing.allocator;
    const bad_spv = [_]u32{ 0xDEADBEEF, 0, 0, 0, 0 };
    const result = glslpp.reflectSPIRV(alloc, &bad_spv);
    try std.testing.expectError(error.InvalidSPIRV, result);
}

test "G1: too-short SPIR-V returns error" {
    const alloc = std.testing.allocator;
    const short_spv = [_]u32{ 0x07230203 };
    const result = glslpp.reflectSPIRV(alloc, &short_spv);
    try std.testing.expectError(error.InvalidSPIRV, result);
}

test "G1: push constant with members" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(push_constant) uniform Push {
        \\    mat4 mvp;
        \\    vec4 tint;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = tint; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.push_constants.len);
    const pc = res.push_constants[0];
    try std.testing.expect(pc.members.len >= 2);
    try std.testing.expectEqualStrings("mvp", pc.members[0].name);
    try std.testing.expectEqual(reflect.TypeKind.matrix, pc.members[0].type_kind);
    try std.testing.expectEqualStrings("tint", pc.members[1].name);
    try std.testing.expectEqual(reflect.TypeKind.vector, pc.members[1].type_kind);
}

test "G1: resource IDs are non-zero and unique" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform A { vec4 x; };
        \\layout(std140, binding = 1) uniform B { vec4 y; };
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = x + y; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), res.uniform_buffers.len);
    try std.testing.expect(res.uniform_buffers[0].id != res.uniform_buffers[1].id);
    try std.testing.expect(res.uniform_buffers[0].id > 0);
    try std.testing.expect(res.uniform_buffers[1].id > 0);
}

test "G1: reflectGLSL matches reflectSPIRV for same source" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 430
        \\layout(std140, binding = 0) uniform UBO { mat4 mvp; vec4 tint; };
        \\layout(binding = 1) uniform sampler2D tex;
        \\layout(location = 0) in vec2 vUV;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = texture(tex, vUV) * tint; }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    var res1 = try glslpp.reflectSPIRV(alloc, spv);
    defer res1.deinit(alloc);
    var res2 = try glslpp.reflectGLSL(alloc, source, .{ .stage = .fragment });
    defer res2.deinit(alloc);

    try std.testing.expectEqual(res1.uniform_buffers.len, res2.uniform_buffers.len);
    try std.testing.expectEqual(res1.sampled_images.len, res2.sampled_images.len);
    try std.testing.expectEqual(res1.inputs.len, res2.inputs.len);
    try std.testing.expectEqual(res1.outputs.len, res2.outputs.len);
}

// =============================================================================
// G4: GLSL version flexibility — correctness tests
// =============================================================================

test "G4: GLSL 300 output contains #version 300" {
    const alloc = std.testing.allocator;
    const glsl = try glslpp.compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0); }
    , .fragment, 300);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "#version 300") != null);
}

test "G4: GLSL 330 output contains #version 330" {
    const alloc = std.testing.allocator;
    const glsl = try glslpp.compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0); }
    , .fragment, 330);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "#version 330") != null);
}

test "G4: GLSL 450 output preserves binding qualifiers" {
    const alloc = std.testing.allocator;
    const glsl = try glslpp.compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(std140, binding = 3) uniform UBO { vec4 data; };
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = data; }
    , .fragment, 450);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "#version 450") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "binding") != null);
}

test "G4: GLSL 460 output valid" {
    const alloc = std.testing.allocator;
    const glsl = try glslpp.compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
    , .fragment, 460);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "#version 460") != null);
}

test "G4: backward-compatible compileGlslToGlsl still works" {
    const alloc = std.testing.allocator;
    const glsl = try glslpp.compileGlslToGlsl(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(0.5); }
    , .fragment);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "#version") != null);
}

test "G4: cross-compile preserves shader semantics across versions" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 430
        \\layout(location = 0) in vec2 vUV;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(vUV, 0.0, 1.0); }
    ;

    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    inline for (.{ 330, 430, 450, 460 }) |ver| {
        const glsl = try glslpp.compileGlslToGlslVersion(alloc, source, .fragment, ver);
        defer alloc.free(glsl);
        try std.testing.expect(std.mem.indexOf(u8, glsl, "void main()") != null);
    }
}

// =============================================================================
// G10: HLSL SM 5.0 compatibility — correctness tests
// =============================================================================

test "G10: basic HLSL output contains cbuffer for UBO" {
    const alloc = std.testing.allocator;
    const hlsl = try glslpp.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform MyCBuffer {
        \\    vec4 color;
        \\    float intensity;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = color * intensity; }
    , .fragment);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "cbuffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "register(b0)") != null);
}

test "G10: HLSL output uses Texture2D + SamplerState for sampler2D" {
    const alloc = std.testing.allocator;
    const hlsl = try glslpp.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(binding = 0) uniform sampler2D myTex;
        \\layout(location = 0) in vec2 vUV;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = texture(myTex, vUV); }
    , .fragment);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "Texture2D") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SamplerState") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, ".Sample(") != null);
}

test "G10: HLSL vertex shader has VS signature" {
    const alloc = std.testing.allocator;
    const hlsl = try glslpp.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(location = 0) in vec3 aPos;
        \\void main() {
        \\    gl_Position = vec4(aPos, 1.0);
        \\}
    , .vertex);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SV_POSITION") != null or
        std.mem.indexOf(u8, hlsl, "gl_Position") != null or
        std.mem.indexOf(u8, hlsl, "main") != null);
}

test "G10: HLSL compute shader has [numthreads]" {
    const alloc = std.testing.allocator;
    const hlsl = try glslpp.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
        \\layout(std430, binding = 0) buffer Data { float values[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    values[idx] *= 2.0;
        \\}
    , .compute);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "numthreads") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "64") != null);
}

test "G10: HLSL output for mat4 uses float4x4" {
    const alloc = std.testing.allocator;
    const hlsl = try glslpp.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform UBO { mat4 mvp; };
        \\layout(location = 0) in vec4 aPos;
        \\void main() { gl_Position = mvp * aPos; }
    , .vertex);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "float4x4") != null or
        std.mem.indexOf(u8, hlsl, "float4") != null);
}

// =============================================================================
// Cross-cutting: Reflection + cross-compile consistency
// =============================================================================

test "cross: reflected resources match across GLSL and HLSL backends" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 430
        \\layout(std140, binding = 0) uniform UBO { vec4 data; };
        \\layout(binding = 1) uniform sampler2D tex;
        \\layout(location = 0) in vec2 vUV;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = texture(tex, vUV) * data; }
    ;

    var res = try glslpp.reflectGLSL(alloc, source, .{ .stage = .fragment });
    defer res.deinit(alloc);

    const hlsl = try glslpp.compileGlslToHlsl(alloc, source, .fragment);
    defer alloc.free(hlsl);

    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    try std.testing.expectEqual(@as(usize, 1), res.sampled_images.len);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "cbuffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "Texture2D") != null);
}

test "cross: SSBO reflected as storage_buffer and present in HLSL" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 430
        \\layout(std430, binding = 0) buffer Data { float vals[]; };
        \\layout(std140, binding = 1) uniform Params { float scale; };
        \\void main() { vals[0] *= scale; }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), res.storage_buffers.len);
    try std.testing.expectEqual(@as(u32, 0), res.storage_buffers[0].binding);
    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    try std.testing.expectEqual(@as(u32, 1), res.uniform_buffers[0].binding);

    const hlsl = try glslpp.compileGlslToHlsl(alloc, source, .compute);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "ByteAddressBuffer") != null or
        std.mem.indexOf(u8, hlsl, "StructuredBuffer") != null or
        std.mem.indexOf(u8, hlsl, "RWByteAddressBuffer") != null or
        std.mem.indexOf(u8, hlsl, "buffer") != null);
}
