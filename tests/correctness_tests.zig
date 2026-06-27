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

test "G4: GLSL 300 (ESSL) is rejected with an honest error" {
    // #169: 300 is OpenGL ES Shading Language, which glslpp intentionally does NOT
    // emit. Requesting it must fail loudly rather than silently produce an invalid
    // or wrong-dialect #version. Mirrors the honest-error gate in root.zig.
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedGlslVersion, glslpp.compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0); }
    , .fragment, 300));
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

fn spirvHasWord(spv: []const u32, word: u32) bool {
    for (spv) |w| if (w == word) return true;
    return false;
}

/// True if the SPIR-V module contains at least one instruction with `opcode`
/// (low 16 bits of the instruction header word). Walks instructions by word
/// count, skipping the 5-word module header.
fn spirvHasOpcode(spv: []const u32, opcode: u16) bool {
    var idx: usize = 5;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (@as(u16, @truncate(spv[idx] & 0xFFFF)) == opcode) return true;
        if (wc == 0) break;
        idx += wc;
    }
    return false;
}

// Scan the SPIR-V module for an OpTypeImage (opcode 25) with Dim==Buffer (5)
// whose sampled-type id resolves to a scalar of the requested kind:
//   .float → OpTypeFloat, .int → signed OpTypeInt, .uint → unsigned OpTypeInt.
// Used by the #194 isamplerBuffer/usamplerBuffer regression tests to prove the
// emitted texel-buffer image carries the correct component type (not an empty
// OpTypeStruct, the pre-fix silent-wrong fallthrough).
const SampledKind = enum { float, int, uint };
fn spirvHasBufferImageOfKind(spv: []const u32, want: SampledKind) bool {
    // First pass: record result-id → scalar kind for OpTypeFloat / OpTypeInt.
    var idx: usize = 5; // skip 5-word header
    // result_id → 0:none, 1:float, 2:int-signed, 3:int-unsigned
    var kinds = std.AutoHashMap(u32, SampledKind).init(std.testing.allocator);
    defer kinds.deinit();
    while (idx < spv.len) {
        const word_count = spv[idx] >> 16;
        const opcode = spv[idx] & 0xFFFF;
        if (word_count == 0) break;
        if (opcode == 22 and idx + 2 < spv.len) { // OpTypeFloat result, width
            kinds.put(spv[idx + 1], .float) catch {};
        } else if (opcode == 21 and idx + 3 < spv.len) { // OpTypeInt result, width, signedness
            kinds.put(spv[idx + 1], if (spv[idx + 3] == 1) .int else .uint) catch {};
        }
        idx += word_count;
    }
    // Second pass: find OpTypeImage with Dim==Buffer and matching sampled type.
    idx = 5;
    while (idx < spv.len) {
        const word_count = spv[idx] >> 16;
        const opcode = spv[idx] & 0xFFFF;
        if (word_count == 0) break;
        // OpTypeImage: result(1) sampled_type(2) Dim(3) ...
        if (opcode == 25 and idx + 3 < spv.len) {
            const sampled_type = spv[idx + 2];
            const dim = spv[idx + 3];
            if (dim == 5) { // Buffer
                if (kinds.get(sampled_type)) |k| {
                    if (k == want) return true;
                }
            }
        }
        idx += word_count;
    }
    return false;
}

fn spirvHasOp(spv: []const u32, opcode: u32) bool {
    var idx: usize = 5;
    while (idx < spv.len) {
        const word_count = spv[idx] >> 16;
        if (word_count == 0) break;
        if ((spv[idx] & 0xFFFF) == opcode) return true;
        idx += word_count;
    }
    return false;
}

// #194: isamplerBuffer/usamplerBuffer used to have no parser keyword and (had it
// reached codegen) fell through to an empty OpTypeStruct → "Expected Image to be
// of type OpTypeImage" in spirv-val. Now they emit OpTypeImage <int|uint> Buffer.
test "gap#194: isamplerBuffer emits OpTypeImage with int component (texelFetch/textureSize)" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding = 0) uniform isamplerBuffer s;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec4 v = texelFetch(s, 3);
        \\    int n = textureSize(s);
        \\    o = vec4(v) + vec4(float(n));
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasBufferImageOfKind(spv, .int));
    try std.testing.expect(spirvHasOp(spv, 95)); // OpImageFetch
    try std.testing.expect(spirvHasOp(spv, 104)); // OpImageQuerySize
}

test "gap#194: usamplerBuffer emits OpTypeImage with uint component (texelFetch/textureSize)" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding = 0) uniform usamplerBuffer s;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uvec4 v = texelFetch(s, 3);
        \\    int n = textureSize(s);
        \\    o = vec4(v) + vec4(float(n));
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasBufferImageOfKind(spv, .uint));
    try std.testing.expect(spirvHasOp(spv, 95)); // OpImageFetch
    try std.testing.expect(spirvHasOp(spv, 104)); // OpImageQuerySize
}

test "gap#194 regression: float samplerBuffer still emits OpTypeImage with float component" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding = 0) uniform samplerBuffer s;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = texelFetch(s, 3);
        \\    int n = textureSize(s);
        \\    o = v + vec4(float(n));
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasBufferImageOfKind(spv, .float));
    try std.testing.expect(!spirvHasBufferImageOfKind(spv, .int));
    try std.testing.expect(!spirvHasBufferImageOfKind(spv, .uint));
}

test "fold: signed int literal in float-vector ctor wraps (two's complement) like glslang" {
    // Regression: `vec2(2147483648, 0)` — a bare decimal literal is a 32-bit
    // SIGNED int in GLSL, so 2^31 wraps to -2147483648; glslang folds the vec
    // component to -2.147e9. A bare @floatFromInt on the u32 word silently gave
    // +2.147e9 (sign flip = silent-wrong). f32 bit patterns: -2147483648.0 =
    // 0xCF000000, +2147483648.0 = 0x4F000000.
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location = 0) out vec2 o;
        \\void main() { o = vec2(2147483648, 0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasWord(spv, 0xCF000000)); // -2.147e9 (correct)
    try std.testing.expect(!spirvHasWord(spv, 0x4F000000)); // not the sign-flipped +2.147e9
}

test "fold: unsigned literal in float-vector ctor stays positive" {
    // The `u` suffix makes it unsigned — 2147483648u is +2.147e9 (= 0x4F000000),
    // matching glslang. Guards against over-correcting the signed fix.
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location = 0) out vec2 o;
        \\void main() { o = vec2(2147483648u, 0u); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasWord(spv, 0x4F000000)); // +2.147e9 (correct)
    try std.testing.expect(!spirvHasWord(spv, 0xCF000000));
}

test "frontend: separate sampler2DShadow(tex,samp) emits a depth-compare, not OpUndef" {
    // A Vulkan SEPARATE comparison sampler — `texture(sampler2DShadow(tex, samp),
    // coord)` built from a distinct texture2D + samplerShadow — was DROPPED by the
    // frontend: parsePrimary did not list the shadow sampler keywords as
    // constructors, so the constructor (and the whole statement) never parsed and
    // the depth compare vanished (empty main / OpUndef result = silent-wrong).
    // Assert the emitted SPIR-V now contains an OpImageSampleDref* op.
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 310 es
        \\precision mediump float;
        \\layout(set = 0, binding = 0) uniform mediump samplerShadow uS;
        \\layout(set = 0, binding = 1) uniform texture2D uT;
        \\layout(location = 0) out float o;
        \\void main() { o = texture(sampler2DShadow(uT, uS), vec3(0.5)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    // OpImageSampleDrefImplicitLod = 89.
    try std.testing.expect(spirvHasOpcode(spv, 89));
}

test "frontend: separate sampler2DShadow with textureLod emits explicit-lod depth-compare" {
    // Same root cause via the EXPLICIT-LOD path: textureLod(sampler2DShadow(...),
    // …) must lower to OpImageSampleDrefExplicitLod (90), not be dropped.
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(set = 0, binding = 0) uniform samplerShadow uS;
        \\layout(set = 0, binding = 1) uniform texture2D uT;
        \\layout(location = 0) out float o;
        \\void main() { o = textureLod(sampler2DShadow(uT, uS), vec3(0.5), 0.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 90)); // OpImageSampleDrefExplicitLod
}

// #170: textureOffset(sampler2DShadow, coord, const ivec offset) — the 3-arg form
// (no bias) — emitted INVALID SPIR-V at rc=0. It routes to OpImageSampleDrefImplicitLod,
// whose 3-operand codegen path assumes a FLOAT Bias operand (it can't tell the
// ivec2 offset apart from `texture(shadow, coord, bias)` by arg count), so it
// emitted the ivec2 as a Bias → spirv-val: "Expected Image Operand Bias to be a
// 32-bit float scalar". glslang accepts the GLSL, so it must honest-error rather
// than mis-compile (a full dref-ConstOffset lowering is a follow-up).
test "frontend: 3-arg shadow textureOffset honest-errors (was invalid SPIR-V), siblings still compile" {
    const alloc = std.testing.allocator;
    // The broken case → honest error (not invalid SPIR-V).
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(textureOffset(sh, vec3(uv, 0.5), ivec2(1))); }
    , .{ .stage = .fragment }));

    // Siblings that DO lower correctly must keep working (no over-rejection):
    //   texture(shadow, coord, bias) — float Bias, valid.
    //   textureLodOffset(shadow, ...) — Lod-disambiguated explicit-lod ConstOffset.
    //   textureOffset(shadow, coord, offset, bias) — 4-arg Bias|ConstOffset.
    const ok_srcs = [_][:0]const u8{
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(texture(sh, vec3(uv, 0.5), 0.1)); }
        ,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(textureLodOffset(sh, vec3(uv, 0.5), 0.0, ivec2(1))); }
        ,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(textureOffset(sh, vec3(uv, 0.5), ivec2(1), 0.1)); }
    };
    for (ok_srcs) |src| {
        const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 89) or spirvHasOpcode(spv, 90)); // a Dref sample op
    }
}

// #170: UNSIGNED relational comparisons (uint/uvecN `<` `>` `<=` `>=`, and the
// lessThan/greaterThan-family builtins) were lowered to the SIGNED SPIR-V ops
// (OpSLessThan etc.) — a SILENT-WRONG: valid SPIR-V that spirv-val/naga accept,
// but WRONG results for operands >= 2^31 (signed sees them as negative). glslang
// emits OpULessThan/OpUGreaterThan/... Must use the unsigned ops.
// SPIR-V opcodes: ULessThan=176 SLessThan=177; UGreaterThan=172 SGreaterThan=173;
// ULessThanEqual=178 SLessThanEqual=179; UGreaterThanEqual=174 SGreaterThanEqual=175.
test "frontend: unsigned comparisons emit OpU* (not signed) — operator + builtin forms" {
    const alloc = std.testing.allocator;
    // Operator form on uvec.
    {
        const spv = try glslpp.compileToSPIRV(alloc,
            \\#version 450
            \\layout(location=0) flat in uvec2 a;
            \\layout(location=1) flat in uvec2 b;
            \\layout(location=0) out vec4 o;
            \\void main(){ o = (a.x < b.x) ? vec4(greaterThan(a,b), lessThanEqual(a,b)) : vec4(0); }
        , .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 176)); // ULessThan (operator a.x<b.x)
        try std.testing.expect(spirvHasOpcode(spv, 172)); // UGreaterThan (greaterThan builtin)
        try std.testing.expect(spirvHasOpcode(spv, 178)); // ULessThanEqual (lessThanEqual builtin)
        // The SIGNED forms must NOT appear for these unsigned operands.
        try std.testing.expect(!spirvHasOpcode(spv, 177)); // no SLessThan
        try std.testing.expect(!spirvHasOpcode(spv, 173)); // no SGreaterThan
        try std.testing.expect(!spirvHasOpcode(spv, 179)); // no SLessThanEqual
    }
    // SIGNED operands still emit the signed ops (no over-correction / regression).
    {
        const spv = try glslpp.compileToSPIRV(alloc,
            \\#version 450
            \\layout(location=0) flat in ivec2 a;
            \\layout(location=1) flat in ivec2 b;
            \\layout(location=0) out vec4 o;
            \\void main(){ o = (a.x < b.x) ? vec4(1) : vec4(0); }
        , .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 177)); // SLessThan for int operands
        try std.testing.expect(!spirvHasOpcode(spv, 176)); // not ULessThan
    }
    // MIXED int/uint: GLSL promotes to UNSIGNED (the int is bitcast to uint), so
    // `int < uint` must also use OpULessThan — selection checks BOTH operands.
    {
        const spv = try glslpp.compileToSPIRV(alloc,
            \\#version 450
            \\layout(location=0) flat in int si;
            \\layout(location=1) flat in uint ui;
            \\layout(location=0) out vec4 o;
            \\void main(){ o = (si < ui) ? vec4(1) : vec4(0); }
        , .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 176)); // ULessThan (promoted to unsigned)
        try std.testing.expect(!spirvHasOpcode(spv, 177)); // not SLessThan
    }
}

// =============================================================================
// #170: dynamic double-index into a LOCAL matrix must emit valid SPIR-V.
// Repro: `mat3 m = mat3(a,b,c); o = vec4(m[i][j]);` with i,j dynamic.
// The inner `m[i]` lowers to an OpAccessChain (pointer-to-column); the outer
// `[j]` previously fed that POINTER straight into OpVectorExtractDynamic, whose
// vector operand must be a vector VALUE — so the frontend emitted invalid
// SPIR-V (spirv-val: "Expected Vector type to be OpTypeVector"; after DCE the
// dead column pointer left a dangling-ID reference). The column value must be
// LOADED before the dynamic component extract. This is a frontend bug, so a
// valid SPIR-V module is the fix for ALL backends.
// =============================================================================

/// Resolve spirv-val and run it on `spv`. Skips when the tool is unavailable
/// (mirrors the resolveVulkanTool/SkipZigTest pattern used across the suite).
fn spirvValOrSkip(spv: []const u32) !void {
    const alloc = std.testing.allocator;
    const tool = glslpp.compat.resolveVulkanTool(alloc, "spirv-val") catch return error.SkipZigTest;
    defer alloc.free(tool);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile("m.spv", .{});
        defer f.close();
        try f.writeAll(std.mem.sliceAsBytes(spv));
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const spv_path = try tmp.dir.realpath("m.spv", &path_buf);

    const r = std.process.Child.run(.{ .allocator = alloc, .argv = &.{ tool, spv_path } }) catch return error.SkipZigTest;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    if (!(r.term == .Exited and r.term.Exited == 0)) {
        std.debug.print("spirv-val rejected the module:\n{s}\n{s}\n", .{ r.stdout, r.stderr });
        return error.TestSpirvValFailed;
    }
}

const dyn_double_index_src =
    \\#version 450
    \\layout(location=0) in vec3 a; layout(location=1) in vec3 b; layout(location=2) in vec3 c;
    \\layout(location=3) flat in int i; layout(location=4) flat in int j;
    \\layout(location=0) out vec4 o;
    \\void main(){ mat3 m = mat3(a, b, c); o = vec4(m[i][j]); }
;

test "frontend #170: dynamic m[i][j] on a local matrix emits valid SPIR-V (opt)" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, dyn_double_index_src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try spirvValOrSkip(spv);
}

test "frontend #170: dynamic m[i][j] on a local matrix emits valid SPIR-V (no-opt)" {
    // Guards the lowering itself, independent of the optimizer pipeline: the
    // unoptimized module must already be valid (it was not — VectorExtractDynamic
    // on an OpAccessChain pointer).
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRVNoOpt(alloc, dyn_double_index_src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try spirvValOrSkip(spv);
}

test "frontend #170: dynamic m[i][j] cross-compiles to all four backends" {
    // A frontend fix produces valid SPIR-V, which every backend then accepts.
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, dyn_double_index_src, .{ .stage = .fragment });
    defer alloc.free(spv);

    const wgsl = try glslpp.spirvToWGSL(alloc, spv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(wgsl.len > 0);

    const hlsl = try glslpp.spirvToHLSL(alloc, spv, .{});
    defer alloc.free(hlsl);
    try std.testing.expect(hlsl.len > 0);

    const msl = try glslpp.spirvToMSL(alloc, spv, .{});
    defer alloc.free(msl);
    try std.testing.expect(msl.len > 0);

    const glsl = try glslpp.spirvToGLSL(alloc, spv, .{});
    defer alloc.free(glsl);
    try std.testing.expect(glsl.len > 0);
}
