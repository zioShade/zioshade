// M6: MSL argument-buffers cross-compile tests.
//
// Exercises `MslCompileOptions.argument_buffers = true`: a single
// `spvDescriptorSetBuffer0` struct gathers all set-0 resources with
// sequential `[[id(N)]]` slots, and the entry point takes one
// `constant spvDescriptorSetBuffer0& set0 [[buffer(0)]]` parameter
// instead of per-resource bindings.
//
// v1 scope checked here: struct emission + entry signature shape.
// Body correctness (kernel uses local aliases) is covered indirectly
// by the legacy MSL test suite continuing to pass with argbuf=false.

const std = @import("std");
const glslpp = @import("glslpp");

const FIXTURE =
    \\#version 450
    \\layout(set=0, binding=0) uniform U { vec4 c; } u;
    \\layout(set=0, binding=1) uniform sampler2D tex;
    \\layout(location=0) in vec2 uv;
    \\layout(location=0) out vec4 fragColor;
    \\void main() { fragColor = u.c * texture(tex, uv); }
;

test "msl argbuf: emits spvDescriptorSetBuffer0 struct" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, FIXTURE, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const msl = try glslpp.spirvToMSL(alloc, spirv, .{ .argument_buffers = true });
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "struct spvDescriptorSetBuffer0") != null);
}

test "msl argbuf: main signature takes [[buffer(0)]] argument buffer" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, FIXTURE, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const msl = try glslpp.spirvToMSL(alloc, spirv, .{ .argument_buffers = true });
    defer alloc.free(msl);
    // Look for the per-set arg-buffer parameter in the entry signature.
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant spvDescriptorSetBuffer0&") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[buffer(0)]]") != null);
}

test "msl argbuf: emits [[id]] qualifiers inside the set struct" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, FIXTURE, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const msl = try glslpp.spirvToMSL(alloc, spirv, .{ .argument_buffers = true });
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[id(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[id(1)]]") != null);
}

test "msl argbuf: default false preserves per-resource binding" {
    // Negative-control: legacy output unchanged when argument_buffers is false.
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, FIXTURE, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const msl = try glslpp.spirvToMSL(alloc, spirv, .{ .argument_buffers = false });
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "spvDescriptorSetBuffer0") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[buffer(0)]]") != null); // per-resource binding stays
}
