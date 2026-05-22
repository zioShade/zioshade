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
