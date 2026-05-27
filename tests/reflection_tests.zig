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

test "reflection M2.4: storage_image exposes rgba8 format via real GLSL compile" {
    // End-to-end: GLSL `layout(rgba8) image2D` -> codegen emits Format=Rgba8
    // on `OpTypeImage` -> reflection exposes `image_format = .rgba8`.
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(local_size_x=1) in;
        \\layout(set=0, binding=0, rgba8) uniform image2D destImg;
        \\void main() { imageStore(destImg, ivec2(0), vec4(1.0)); }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.storage_images.len);
    try std.testing.expectEqual(@as(?glslpp.reflection.ImageFormat, .rgba8), res.storage_images[0].image_format);
}

test "reflection M2.4: storage_image format rgba32f" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(local_size_x=1) in;
        \\layout(set=0, binding=0, rgba32f) uniform image2D destImg;
        \\void main() { imageStore(destImg, ivec2(0), vec4(1.0)); }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.storage_images.len);
    try std.testing.expectEqual(@as(?glslpp.reflection.ImageFormat, .rgba32f), res.storage_images[0].image_format);
}

test "reflection M2.4: storage_image format r32i" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(local_size_x=1) in;
        \\layout(set=0, binding=0, r32i) uniform iimage2D destImg;
        \\void main() { imageStore(destImg, ivec2(0), ivec4(1)); }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.storage_images.len);
    try std.testing.expectEqual(@as(?glslpp.reflection.ImageFormat, .r32i), res.storage_images[0].image_format);
}

test "reflection M2.4: storage_image format r32ui" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(local_size_x=1) in;
        \\layout(set=0, binding=0, r32ui) uniform uimage2D destImg;
        \\void main() { imageStore(destImg, ivec2(0), uvec4(1)); }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.storage_images.len);
    try std.testing.expectEqual(@as(?glslpp.reflection.ImageFormat, .r32ui), res.storage_images[0].image_format);
}

test "reflection M2.4: storage_image without format qualifier reports null" {
    // Sanity: when GLSL omits the format qualifier, codegen emits
    // `ImageFormat=Unknown` and reflection surfaces `null`.
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 430
        \\layout(local_size_x=1) in;
        \\layout(set=0, binding=0) uniform image2D destImg;
        \\void main() { imageStore(destImg, ivec2(0), vec4(1.0)); }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.storage_images.len);
    try std.testing.expectEqual(@as(?glslpp.reflection.ImageFormat, null), res.storage_images[0].image_format);
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
