// SPDX-License-Identifier: MIT OR Apache-2.0
// M8.3: binding_shift option for GLSL/MSL/WGSL backends.
//
// Each test compiles a minimal fragment shader with a uniform buffer at
// `layout(set=0, binding=2)` to SPIR-V, then cross-compiles with
// `binding_shift = -1` and asserts the output mentions binding=1 in the
// backend-appropriate syntax (binding=1 / [[buffer(1)]] / @binding(1)).
//
// The HLSL backend already has this option (see spirv_to_hlsl.zig) — M8.3
// brings the other three backends to feature parity.

const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

const SHADER_BINDING_2 =
    \\#version 450
    \\layout(set=0, binding=2) uniform U { vec4 color; } u;
    \\layout(location=0) out vec4 fragColor;
    \\void main() {
    \\    fragColor = u.color;
    \\}
;

fn assertContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle)) |_| return;
    std.debug.print("Expected to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
    return error.TestExpectedFind;
}

test "binding_shift: GLSL binding=2 with shift=-1 emits binding=1" {
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_BINDING_2, .{ .stage = .fragment });
    defer alloc.free(spv);

    // Sanity: with default shift=0, output should mention binding = 2.
    const baseline = try glslpp.spirvToGLSL(alloc, spv, .{ .version = 450 });
    defer alloc.free(baseline);
    try assertContains(baseline, "binding = 2");

    // With shift=-1, output should mention binding = 1 instead.
    const shifted = try glslpp.spirvToGLSL(alloc, spv, .{ .version = 450, .binding_shift = -1 });
    defer alloc.free(shifted);
    try assertContains(shifted, "binding = 1");
}

test "binding_shift: MSL binding=2 with shift=-1 emits [[buffer(1)]]" {
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_BINDING_2, .{ .stage = .fragment });
    defer alloc.free(spv);

    const baseline = try glslpp.spirvToMSL(alloc, spv, .{});
    defer alloc.free(baseline);
    try assertContains(baseline, "[[buffer(2)]]");

    const shifted = try glslpp.spirvToMSL(alloc, spv, .{ .binding_shift = -1 });
    defer alloc.free(shifted);
    try assertContains(shifted, "[[buffer(1)]]");
}

test "binding_shift: WGSL @binding is shifted" {
    // The WGSL backend re-encodes set+binding as `binding*2 + set` to derive
    // @group=binding/2. For set=0 binding=2 that produces an internal binding
    // of 4, which is what shows up in @binding(N). Apply shift -3 to land on
    // @binding(1).
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_BINDING_2, .{ .stage = .fragment });
    defer alloc.free(spv);

    const baseline = try glslpp.spirvToWGSL(alloc, spv, .{});
    defer alloc.free(baseline);
    try assertContains(baseline, "@binding(4)");

    const shifted = try glslpp.spirvToWGSL(alloc, spv, .{ .binding_shift = -3 });
    defer alloc.free(shifted);
    try assertContains(shifted, "@binding(1)");
}
