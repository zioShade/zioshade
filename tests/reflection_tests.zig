const std = @import("std");
const glslpp = @import("glslpp");

test "reflectSPIRV finds uniform buffer" {
    const alloc = std.testing.allocator;
    const spv_refl = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform MyUB {
        \\    vec4 color;
        \\    float intensity;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = color * intensity; }
    , .{ .stage = .fragment });
    defer alloc.free(spv_refl);
    var res = try glslpp.reflectSPIRV(alloc, spv_refl);
    defer res.deinit(alloc);
    try std.testing.expect(res.uniform_buffers.len == 1);
    try std.testing.expect(res.uniform_buffers[0].binding == 0);
    try std.testing.expect(res.outputs.len >= 1);
}

test "reflectSPIRV finds inputs and outputs" {
    const alloc = std.testing.allocator;
    const spv_io = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(location = 0) in vec2 vUV;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(vUV, 0.0, 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv_io);
    var res = try glslpp.reflectSPIRV(alloc, spv_io);
    defer res.deinit(alloc);
    try std.testing.expect(res.inputs.len >= 1);
    try std.testing.expect(res.outputs.len >= 1);
}

test "reflectSPIRV finds sampled image" {
    const alloc = std.testing.allocator;
    const spv_tex = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(binding = 0) uniform sampler2D myTex;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = texture(myTex, vec2(0.5)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv_tex);
    var res = try glslpp.reflectSPIRV(alloc, spv_tex);
    defer res.deinit(alloc);
    try std.testing.expect(res.sampled_images.len == 1);
    try std.testing.expect(res.sampled_images[0].binding == 0);
}

test "reflectSPIRV finds entry point" {
    const alloc = std.testing.allocator;
    const spv_ep = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv_ep);
    var res = try glslpp.reflectSPIRV(alloc, spv_ep);
    defer res.deinit(alloc);
    try std.testing.expect(res.entry_points.len == 1);
    try std.testing.expect(res.entry_points[0].stage == .fragment);
}

test "reflectGLSL convenience function" {
    const alloc = std.testing.allocator;
    var res = try glslpp.reflectGLSL(alloc,
        \\#version 430
        \\layout(std140, binding = 2) uniform Data { mat4 mvp; };
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = mvp * vec4(1.0); }
    , .{ .stage = .fragment });
    defer res.deinit(alloc);
    try std.testing.expect(res.uniform_buffers.len == 1);
    try std.testing.expect(res.uniform_buffers[0].binding == 2);
}

test "reflectSPIRV finds UBO members" {
    const alloc = std.testing.allocator;
    const spv_mem = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform MyUB {
        \\    vec4 color;
        \\    float intensity;
        \\    mat4 transform;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = color * intensity; }
    , .{ .stage = .fragment });
    defer alloc.free(spv_mem);
    var res = try glslpp.reflectSPIRV(alloc, spv_mem);
    defer res.deinit(alloc);
    try std.testing.expect(res.uniform_buffers.len == 1);
    const ubo = res.uniform_buffers[0];
    try std.testing.expect(ubo.members.len >= 2); // at least color + intensity
}

test "reflectSPIRV finds push constants" {
    const alloc = std.testing.allocator;
    const spv_pc = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(push_constant) uniform PushConsts {
        \\    vec4 data;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = data; }
    , .{ .stage = .fragment });
    defer alloc.free(spv_pc);
    var res = try glslpp.reflectSPIRV(alloc, spv_pc);
    defer res.deinit(alloc);
    try std.testing.expect(res.push_constants.len == 1);
}

test "reflectSPIRV finds storage buffer" {
    const alloc = std.testing.allocator;
    const spv_ssbo = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std430, binding = 0) buffer InputBuf { float input_data[]; };
        \\layout(std430, binding = 1) buffer OutputBuf { float output_data[]; };
        \\void main() { output_data[0] = input_data[0] * 2.0; }
    , .{ .stage = .compute });
    defer alloc.free(spv_ssbo);
    var res = try glslpp.reflectSPIRV(alloc, spv_ssbo);
    defer res.deinit(alloc);
    try std.testing.expect(res.storage_buffers.len == 2);
}

// ── M2 reflection completion ─────────────────────────────────────────

test "reflection M2.1: storage_images populated for writable image2D" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(local_size_x = 1) in;
        \\layout(set = 0, binding = 0, rgba8) uniform image2D destImg;
        \\void main() { imageStore(destImg, ivec2(0), vec4(1.0)); }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.storage_images.len);
    try std.testing.expectEqualStrings("destImg", res.storage_images[0].name);
    try std.testing.expectEqual(@as(u32, 0), res.storage_images[0].set);
    try std.testing.expectEqual(@as(u32, 0), res.storage_images[0].binding);
}

test "reflection M2.4: storage_image exposes rgba8 format from explicit OpTypeImage" {
    // Hand-crafted minimal SPIR-V module exposing a storage image with
    // explicit Format=Rgba8 (SPIR-V Image Format value 4). We don't go
    // through glslpp's GLSL→SPIR-V codegen here because that path currently
    // emits Format=Unknown for `layout(rgba8) image2D` (separate codegen
    // bug; reflection-side handling is the M2.4 scope).
    const alloc = std.testing.allocator;
    const words = [_]u32{
        // SPIR-V header
        0x07230203, // magic
        0x00010000, // version 1.0
        0x000d000d, // generator
        20,         // ID bound
        0,          // schema
        // OpCapability Shader (opcode 17, wc 2)
        (2 << 16) | 17, 1,
        // OpMemoryModel Logical GLSL450 (opcode 14, wc 3)
        (3 << 16) | 14, 0, 1,
        // OpEntryPoint GLCompute %2 "main" (opcode 15, wc 5: model, id, "main\0")
        (5 << 16) | 15, 5, 2, 0x6e69616d, 0x00000000,
        // OpExecutionMode %2 LocalSize 1 1 1 (opcode 16, wc 6)
        (6 << 16) | 16, 2, 17, 1, 1, 1,
        // OpName %2 "main" (opcode 5, wc 4)
        (4 << 16) | 5, 2, 0x6e69616d, 0x00000000,
        // OpDecorate %5 DescriptorSet 0 (opcode 71, wc 4)
        (4 << 16) | 71, 5, 34, 0,
        // OpDecorate %5 Binding 0 (opcode 71, wc 4)
        (4 << 16) | 71, 5, 33, 0,
        // %3 = OpTypeVoid (opcode 19, wc 2)
        (2 << 16) | 19, 3,
        // %4 = OpTypeFunction %3 (opcode 33, wc 3)
        (3 << 16) | 33, 4, 3,
        // %6 = OpTypeFloat 32 (opcode 22, wc 3)
        (3 << 16) | 22, 6, 32,
        // %7 = OpTypeImage %6 2D 0 0 0 2 Rgba8 (opcode 25, wc 9)
        //                                ^----- Sampled=2 (storage image)
        //                                  ^--- Format=4 (Rgba8)
        (9 << 16) | 25, 7, 6, 1, 0, 0, 0, 2, 4,
        // %8 = OpTypePointer UniformConstant %7 (opcode 32, wc 4: result, storage_class=0, pointee)
        (4 << 16) | 32, 8, 0, 7,
        // %5 = OpVariable %8 UniformConstant (opcode 59, wc 4)
        (4 << 16) | 59, 8, 5, 0,
        // %2 = OpFunction %3 None %4 (opcode 54, wc 5)
        (5 << 16) | 54, 3, 2, 0, 4,
        // OpLabel %9 (opcode 248, wc 2)
        (2 << 16) | 248, 9,
        // OpReturn (opcode 253, wc 1)
        (1 << 16) | 253,
        // OpFunctionEnd (opcode 56, wc 1)
        (1 << 16) | 56,
    };
    var res = try glslpp.reflectSPIRV(alloc, &words);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.storage_images.len);
    try std.testing.expectEqual(@as(?glslpp.reflection.ImageFormat, .rgba8), res.storage_images[0].image_format);
}

test "reflection M2.2: subpass_inputs populated for subpassInput" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput depthInput;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = subpassLoad(depthInput); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.subpass_inputs.len);
}

test "reflection M2.3: spec constant default value extracted" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(constant_id = 7) const int SIZE = 42;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(SIZE)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.specialization_constants.len);
    try std.testing.expectEqual(@as(u32, 7), res.specialization_constants[0].spec_id);
    try std.testing.expectEqual(@as(u32, 42), res.specialization_constants[0].default_value_u32);
}

// ── M2.5: previously-untested categories ──

test "reflection M2.5: separate_images populated for texture2D + sampler" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(set = 0, binding = 0) uniform texture2D myTex;
        \\layout(set = 0, binding = 1) uniform sampler mySamp;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = texture(sampler2D(myTex, mySamp), uv); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.separate_images.len);
    try std.testing.expectEqual(@as(usize, 1), res.separate_samplers.len);
    try std.testing.expectEqualStrings("myTex", res.separate_images[0].name);
    try std.testing.expectEqualStrings("mySamp", res.separate_samplers[0].name);
}

test "reflection M2.5: acceleration_structures populated for accelerationStructureEXT" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 460
        \\#extension GL_KHR_ray_tracing : require
        \\layout(set = 0, binding = 0) uniform accelerationStructureEXT topLevel;
        \\layout(location = 0) rayPayloadEXT vec3 payload;
        \\void main() {
        \\    traceRayEXT(topLevel, 0u, 0xff, 0u, 0u, 0u, vec3(0.0), 0.001, vec3(0.0, 0.0, 1.0), 10000.0, 0);
        \\}
    , .{ .stage = .raygen, .spirv_version = .@"1.4" });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.acceleration_structures.len);
    try std.testing.expectEqualStrings("topLevel", res.acceleration_structures[0].name);
}
