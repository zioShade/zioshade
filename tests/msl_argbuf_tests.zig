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

// ---- M6 v2.a: multiple descriptor sets ----

// Two-set fragment fixture: UBO in set=0, UBO in set=1.
const FIXTURE_TWO_SETS_FRAG =
    \\#version 450
    \\layout(set=0, binding=0) uniform A { vec4 a; } ua;
    \\layout(set=1, binding=0) uniform B { vec4 b; } ub;
    \\layout(location=0) out vec4 fragColor;
    \\void main() { fragColor = ua.a + ub.b; }
;

test "msl argbuf v2.a: two-set fragment emits two set structs" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, FIXTURE_TWO_SETS_FRAG, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const msl = try glslpp.spirvToMSL(alloc, spirv, .{ .argument_buffers = true });
    defer alloc.free(msl);
    // Two per-set structs.
    try std.testing.expect(std.mem.indexOf(u8, msl, "struct spvDescriptorSetBuffer0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "struct spvDescriptorSetBuffer1") != null);
    // Each restarts [[id]] numbering at 0; with one resource per set, no [[id(1)]] should appear.
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[id(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[id(1)]]") == null);
    // Two entry params, one per set.
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant spvDescriptorSetBuffer0&") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant spvDescriptorSetBuffer1&") != null);
}

// ---- M6 v2.b: SSBO inside the set struct ----

const FIXTURE_SSBO_COMPUTE =
    \\#version 450
    \\layout(local_size_x=1) in;
    \\layout(set=0, binding=0) buffer Buf { float data[]; } sb;
    \\void main() { sb.data[0] = 1.0; }
;

test "msl argbuf v2.b: SSBO emits inside set struct, no standalone param" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, FIXTURE_SSBO_COMPUTE, .{ .stage = .compute, .version = 450 });
    defer alloc.free(spirv);
    const msl = try glslpp.spirvToMSL(alloc, spirv, .{ .argument_buffers = true });
    defer alloc.free(msl);
    // SSBO appears as device pointer inside the set struct.
    try std.testing.expect(std.mem.indexOf(u8, msl, "struct spvDescriptorSetBuffer0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "device Buf* sb [[id(0)]]") != null);
    // The set struct is bound as the entry-point param.
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant spvDescriptorSetBuffer0& set0 [[buffer(0)]]") != null);
    // No standalone SSBO parameter on the kernel signature.
    try std.testing.expect(std.mem.indexOf(u8, msl, "device Buf* sb [[buffer(") == null);
}

// ---- M6 v2.a + v2.b combined: SSBO in set 0, UBO in set 1 ----

const FIXTURE_MIXED_COMPUTE =
    \\#version 450
    \\layout(local_size_x=1) in;
    \\layout(set=0, binding=0) buffer Buf { float data[]; } sb;
    \\layout(set=1, binding=0) uniform U { vec4 c; } u;
    \\void main() { sb.data[0] = u.c.x; }
;

test "msl argbuf v2.a+v2.b: SSBO in set 0, UBO in set 1" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, FIXTURE_MIXED_COMPUTE, .{ .stage = .compute, .version = 450 });
    defer alloc.free(spirv);
    const msl = try glslpp.spirvToMSL(alloc, spirv, .{ .argument_buffers = true });
    defer alloc.free(msl);
    // Two set structs.
    try std.testing.expect(std.mem.indexOf(u8, msl, "struct spvDescriptorSetBuffer0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "struct spvDescriptorSetBuffer1") != null);
    // SSBO sits in set 0 at [[id(0)]].
    try std.testing.expect(std.mem.indexOf(u8, msl, "device Buf* sb [[id(0)]]") != null);
    // UBO sits in set 1 at [[id(0)]] (numbering restarts per set).
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant U& u [[id(0)]]") != null);
    // No standalone SSBO parameter.
    try std.testing.expect(std.mem.indexOf(u8, msl, "device Buf* sb [[buffer(") == null);
    // Both set params on kernel signature.
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant spvDescriptorSetBuffer0& set0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant spvDescriptorSetBuffer1& set1") != null);
}
