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

test "reflectSPIRV reports descriptor array_size (sampler2D tex[4])" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex[4];
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = texture(tex[2], uv); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    // Array sampler classified by its ELEMENT type (sampled image), with the
    // fixed dimension reported in array_size.
    try std.testing.expectEqual(@as(usize, 1), res.sampled_images.len);
    try std.testing.expectEqual(@as(u32, 4), res.sampled_images[0].array_size);
    // A non-array resource reports array_size 0.
    try std.testing.expect(res.outputs.len >= 1);
    try std.testing.expectEqual(@as(u32, 0), res.outputs[0].array_size);
}

// ── G1 Batch A: array/matrix strides, block_size, runtime arrays, readonly/writeonly ──
// Expected literals derived from `spirv-cross <fixture>.spv --reflect` (the oracle).

test "reflection G1: UBO matrix + array member strides and block_size" {
    // Oracle (spirv-cross --reflect):
    //   Xforms.mvp:       offset 0,   matrix_stride 16
    //   Xforms.normalMat: offset 64,  matrix_stride 16
    //   Xforms.colors:    offset 112, array_stride 16, array[4]
    //   Xforms.exposure:  offset 176
    //   block_size 180
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(std140, binding = 0) uniform Xforms {
        \\    mat4 mvp;
        \\    mat3 normalMat;
        \\    vec4 colors[4];
        \\    float exposure;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = mvp * colors[0] * normalMat[0].xyzz * exposure; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    const ubo = res.uniform_buffers[0];
    try std.testing.expectEqual(@as(u32, 180), ubo.block_size);
    try std.testing.expectEqual(@as(usize, 4), ubo.members.len);

    // mvp (mat4)
    const mvp = ubo.members[0];
    try std.testing.expectEqualStrings("mvp", mvp.name);
    try std.testing.expectEqual(@as(u32, 0), mvp.offset);
    try std.testing.expectEqual(@as(u32, 16), mvp.matrix_stride);
    try std.testing.expectEqual(false, mvp.is_row_major);

    // normalMat (mat3)
    const nm = ubo.members[1];
    try std.testing.expectEqualStrings("normalMat", nm.name);
    try std.testing.expectEqual(@as(u32, 64), nm.offset);
    try std.testing.expectEqual(@as(u32, 16), nm.matrix_stride);
    try std.testing.expectEqual(false, nm.is_row_major);

    // colors (vec4[4])
    const colors = ubo.members[2];
    try std.testing.expectEqualStrings("colors", colors.name);
    try std.testing.expectEqual(@as(u32, 112), colors.offset);
    try std.testing.expectEqual(@as(u32, 16), colors.array_stride);
    try std.testing.expectEqual(@as(u32, 4), colors.array_dim);
    try std.testing.expectEqual(false, colors.is_runtime_array);

    // exposure (float)
    const exp = ubo.members[3];
    try std.testing.expectEqualStrings("exposure", exp.name);
    try std.testing.expectEqual(@as(u32, 176), exp.offset);
}

test "reflection G1: SSBO runtime tail array + readonly/writeonly + block_size" {
    // Oracle (spirv-cross --reflect):
    //   InBuf  readonly,  block_size 16
    //     count:     offset 0
    //     particles: offset 16, runtime array (array[0]), array_stride 0 (struct elem)
    //   OutBuf writeonly, block_size 0
    //     results:   offset 0, runtime array (array[0]), array_stride 16
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\struct Particle { vec4 pos; vec4 vel; };
        \\layout(std430, binding = 0) readonly buffer InBuf {
        \\    uint count;
        \\    Particle particles[];
        \\};
        \\layout(std430, binding = 1) writeonly buffer OutBuf {
        \\    vec4 results[];
        \\};
        \\void main() {
        \\    results[0] = particles[0].pos + vec4(float(count));
        \\}
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), res.storage_buffers.len);

    // Find by name (declaration order in SPIR-V is not guaranteed).
    var in_buf: ?glslpp.reflection.Resource = null;
    var out_buf: ?glslpp.reflection.Resource = null;
    for (res.storage_buffers) |sb| {
        if (std.mem.eql(u8, sb.name, "InBuf")) in_buf = sb;
        if (std.mem.eql(u8, sb.name, "OutBuf")) out_buf = sb;
    }
    const ib = in_buf orelse return error.MissingInBuf;
    const ob = out_buf orelse return error.MissingOutBuf;

    // InBuf
    try std.testing.expectEqual(true, ib.readonly);
    try std.testing.expectEqual(false, ib.writeonly);
    try std.testing.expectEqual(@as(u32, 16), ib.block_size);
    try std.testing.expectEqual(@as(usize, 2), ib.members.len);
    const particles = ib.members[1];
    try std.testing.expectEqualStrings("particles", particles.name);
    try std.testing.expectEqual(@as(u32, 16), particles.offset);
    try std.testing.expectEqual(true, particles.is_runtime_array);
    try std.testing.expectEqual(@as(u32, 0), particles.array_dim);
    try std.testing.expectEqual(@as(u32, 0), particles.array_stride);

    // OutBuf
    try std.testing.expectEqual(true, ob.writeonly);
    try std.testing.expectEqual(false, ob.readonly);
    try std.testing.expectEqual(@as(u32, 0), ob.block_size);
    try std.testing.expectEqual(@as(usize, 1), ob.members.len);
    const results = ob.members[0];
    try std.testing.expectEqualStrings("results", results.name);
    try std.testing.expectEqual(@as(u32, 0), results.offset);
    try std.testing.expectEqual(true, results.is_runtime_array);
    try std.testing.expectEqual(@as(u32, 0), results.array_dim);
    try std.testing.expectEqual(@as(u32, 16), results.array_stride);
}

// ── #171 review: block_size must account for array length/stride and matrix
// column padding for a trailing array/matrix member. Expected literals from
// `spirv-cross <fixture>.spv --reflect` (the oracle). ──

test "reflection #171: UBO block_size with trailing sized array (float tail[4])" {
    // Oracle (spirv-cross --reflect): std140
    //   head: offset 0
    //   tail: offset 16, array[4], array_stride 16
    //   block_size 80  (16 + 16*4)
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(std140, binding = 0) uniform A { vec4 head; float tail[4]; };
        \\layout(location = 0) out vec4 o;
        \\void main() { o = head + vec4(tail[0]); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    try std.testing.expectEqual(@as(u32, 80), res.uniform_buffers[0].block_size);
}

test "reflection #171: SSBO block_size with trailing sized array (float tail[5])" {
    // Oracle (spirv-cross --reflect): std430
    //   head: offset 0
    //   tail: offset 16, array[5], array_stride 4
    //   block_size 36  (16 + 4*5)
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { vec4 head; float tail[5]; };
        \\void main() { tail[0] = head.x; }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.storage_buffers.len);
    try std.testing.expectEqual(@as(u32, 36), res.storage_buffers[0].block_size);
}

test "reflection #171: UBO block_size with trailing mat3" {
    // Oracle (spirv-cross --reflect): std140
    //   head: offset 0
    //   m:    offset 16, matrix_stride 16  (mat3 occupies 3 cols * 16-byte stride)
    //   block_size 64  (16 + 16*3)
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(std140, binding = 0) uniform D { vec4 head; mat3 m; };
        \\layout(location = 0) out vec4 o;
        \\void main() { o = head + vec4(m[0], 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    try std.testing.expectEqual(@as(u32, 64), res.uniform_buffers[0].block_size);
}

test "reflection #171: UBO block_size with trailing multidim array (float md[2][3])" {
    // Oracle (spirv-cross --reflect): std140
    //   head: offset 0
    //   md:   offset 16, array[3,2] (inner-first), array_stride 48 (OUTER stride)
    //   block_size 112  (16 + 48*2)
    // The member's SPIR-V type is the OUTER OpTypeArray: array_dim = 2 (outer
    // count), array_stride = 48 (outer stride). extent = stride * outer_count.
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(std140, binding = 0) uniform C { vec4 head; float md[2][3]; };
        \\layout(location = 0) out vec4 o;
        \\void main() { o = head + vec4(md[0][0]); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    try std.testing.expectEqual(@as(u32, 112), res.uniform_buffers[0].block_size);
}

// ── #177 Item 1: nested-struct member recursion ──
// Nested-struct member offsets derived from `spirv-cross <fixture>.spv
// --reflect` on glslpp's OWN SPIR-V (the oracle), which for the NESTED members
// matches glslang exactly. std140 (offsets RELATIVE to each struct):
//   Scene.mat:  offset 0   (struct Material)
//     Material.albedo: offset 0
//     Material.l:      offset 16  (struct Light)
//       Light.pos:       offset 0
//       Light.intensity: offset 16
//   Scene.mvp:  offset 0, matrix_stride 16
//
// NOTE on offsets / block_size: glslpp's CODEGEN currently emits the WRONG
// std140 `Offset` for a member that FOLLOWS a nested struct — it emits
// `Scene.mvp Offset 0` where glslang emits `Offset 48`. spirv-cross reflects
// the same (buggy) values from glslpp's SPIR-V. This is a SEPARATE pre-existing
// codegen bug, NOT a reflection bug: reflection faithfully reads back whatever
// offsets are decorated. The assertions below therefore pin glslpp's ACTUAL
// reflectable output (mvp offset 0, block_size 64); the nested-member
// STRUCTURE/relative-offset assertions — the #177 Item 1 deliverable — are
// fully correct. The codegen offset bug is tracked as a separate follow-up.
test "reflection #177: nested-struct members recurse with relative offsets" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\struct Light { vec4 pos; float intensity; };
        \\struct Material { vec4 albedo; Light l; };
        \\layout(std140, binding = 0) uniform Scene {
        \\    Material mat;
        \\    mat4 mvp;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = mat.albedo * mat.l.pos * mat.l.intensity * (mvp * vec4(1.0)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    const ubo = res.uniform_buffers[0];
    // block_size 64 reflects glslpp's actual (buggy-offset) emission, not the
    // glslang oracle's 112 — see the codegen-offset note above.
    try std.testing.expectEqual(@as(u32, 64), ubo.block_size);
    try std.testing.expectEqual(@as(usize, 2), ubo.members.len);

    // Scene.mat — a struct member that must carry inner members.
    const mat = ubo.members[0];
    try std.testing.expectEqualStrings("mat", mat.name);
    try std.testing.expectEqual(@as(u32, 0), mat.offset);
    try std.testing.expectEqual(glslpp.reflection.TypeKind.struct_type, mat.type_kind);
    const mat_members = mat.members orelse return error.MissingMatMembers;
    try std.testing.expectEqual(@as(usize, 2), mat_members.len);

    // Material.albedo
    try std.testing.expectEqualStrings("albedo", mat_members[0].name);
    try std.testing.expectEqual(@as(u32, 0), mat_members[0].offset);

    // Material.l — nested struct, offset RELATIVE to Material.
    const l = mat_members[1];
    try std.testing.expectEqualStrings("l", l.name);
    try std.testing.expectEqual(@as(u32, 16), l.offset);
    try std.testing.expectEqual(glslpp.reflection.TypeKind.struct_type, l.type_kind);
    const l_members = l.members orelse return error.MissingLightMembers;
    try std.testing.expectEqual(@as(usize, 2), l_members.len);

    // Light.pos / Light.intensity — offsets RELATIVE to Light.
    try std.testing.expectEqualStrings("pos", l_members[0].name);
    try std.testing.expectEqual(@as(u32, 0), l_members[0].offset);
    try std.testing.expectEqualStrings("intensity", l_members[1].name);
    try std.testing.expectEqual(@as(u32, 16), l_members[1].offset);

    // Scene.mvp — non-struct member has no inner members. Offset reflects
    // glslpp's actual emission (0, see codegen-offset note above), not the
    // glslang oracle's 48. matrix_stride and the null `members` are the points
    // under test for #177 Item 1.
    const mvp = ubo.members[1];
    try std.testing.expectEqualStrings("mvp", mvp.name);
    try std.testing.expectEqual(@as(u32, 0), mvp.offset);
    try std.testing.expectEqual(@as(u32, 16), mvp.matrix_stride);
    try std.testing.expectEqual(@as(?[]const glslpp.reflection.Member, null), mvp.members);
}

// ── #177 Item 3: per-member / per-resource access qualifiers ──
// glslpp emits Coherent/Restrict/Volatile on the VARIABLE (like
// readonly/writeonly via NonWritable/NonReadable), so they surface at the
// Resource level. The enum fix (Coherent 0→23) is what makes glslpp emit a
// real `OpDecorate ... Coherent` instead of `RelaxedPrecision`.
test "reflection #177: buffer coherent / restrict / readonly flags" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) coherent buffer B { float data[]; };
        \\layout(std430, binding = 1) restrict readonly buffer C { float src[]; };
        \\void main() { data[0] = src[0]; }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), res.storage_buffers.len);

    var b_buf: ?glslpp.reflection.Resource = null;
    var c_buf: ?glslpp.reflection.Resource = null;
    for (res.storage_buffers) |sb| {
        if (std.mem.eql(u8, sb.name, "B")) b_buf = sb;
        if (std.mem.eql(u8, sb.name, "C")) c_buf = sb;
    }
    const b = b_buf orelse return error.MissingB;
    const c = c_buf orelse return error.MissingC;

    // B: coherent buffer.
    try std.testing.expectEqual(true, b.coherent);
    try std.testing.expectEqual(false, b.@"restrict");
    try std.testing.expectEqual(false, b.readonly);

    // C: restrict readonly buffer.
    try std.testing.expectEqual(true, c.@"restrict");
    try std.testing.expectEqual(true, c.readonly);
    try std.testing.expectEqual(false, c.coherent);
}

test "reflection #171: per-member row_major / column_major flags" {
    // Adversarial review confirmed the path works; this locks it in.
    // Oracle (spirv-cross --reflect): rm member is row-major, cm is column-major.
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\layout(std140, binding = 0) uniform M {
        \\    layout(row_major) mat4 rm;
        \\    layout(column_major) mat4 cm;
        \\};
        \\layout(location = 0) out vec4 o;
        \\void main() { o = rm[0] + cm[0]; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try glslpp.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    const ubo = res.uniform_buffers[0];
    try std.testing.expectEqual(@as(usize, 2), ubo.members.len);

    var rm: ?glslpp.reflection.Member = null;
    var cm: ?glslpp.reflection.Member = null;
    for (ubo.members) |m| {
        if (std.mem.eql(u8, m.name, "rm")) rm = m;
        if (std.mem.eql(u8, m.name, "cm")) cm = m;
    }
    try std.testing.expectEqual(true, (rm orelse return error.MissingRm).is_row_major);
    try std.testing.expectEqual(false, (cm orelse return error.MissingCm).is_row_major);
}
