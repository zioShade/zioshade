// SPDX-License-Identifier: MIT OR Apache-2.0
//! Specialization-constant cross-compilation tests (M3 milestone).
//! Verifies that each backend emits its idiomatic spec-const syntax.
const std = @import("std");
const glslpp = @import("glslpp");

const SHADER_INT_SPEC =
    \\#version 450
    \\layout(constant_id = 3) const int N = 8;
    \\layout(location = 0) out vec4 fragColor;
    \\void main() { fragColor = vec4(float(N)); }
;

test "M3.1 WGSL: int spec const emits @id(N) override" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_INT_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@id(3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "override") != null);
    // Default value 8 should appear as `= 8` (i32 path, signed)
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "= 8") != null);
}

test "M3.2 HLSL: int spec const emits [[vk::constant_id(N)]] const" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_INT_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spv, .{ .binding_shift = -1, .shader_model = 60 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[[vk::constant_id(3)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "const int") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "= 8;") != null);
    // The old comment-only placeholder must be gone.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "// specialization constant") == null);
    // NOTE: the spec-const variable name is auto-generated ("v1") rather than
    // user-declared ("N") because codegen does not currently emit OpName for
    // spec constants. Tracked as a follow-up for the codegen layer.
}

// ── M3.3: bool spec consts via OpSpecConstantTrue / OpSpecConstantFalse ──

const SHADER_BOOL_SPEC =
    \\#version 450
    \\layout(constant_id = 1) const bool ENABLE_FX = true;
    \\layout(location = 0) out vec4 fragColor;
    \\void main() { fragColor = ENABLE_FX ? vec4(1.0) : vec4(0.0); }
;

test "M3.3 SPIR-V: bool spec const emits OpSpecConstantTrue (op 48)" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_BOOL_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    // Scan SPIR-V for opcode 48 (OpSpecConstantTrue)
    var found = false;
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (op == 48) { found = true; break; }
        if (wc == 0) break;
        i += wc;
    }
    try std.testing.expect(found);
}

test "M3.3 GLSL: bool spec const cross-compiles to layout(constant_id=N) const bool ... = true" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_BOOL_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const glsl = try glslpp.spirvToGLSL(alloc, spv, .{});
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "layout(constant_id = 1) const bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "= true;") != null);
}

test "M3.3 WGSL: bool spec const cross-compiles to override ... = true" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_BOOL_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@id(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "override") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ": bool = true;") != null);
}

test "M3.3 HLSL: bool spec const cross-compiles to [[vk::constant_id(N)]] const bool ... = true" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_BOOL_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spv, .{ .binding_shift = -1, .shader_model = 60 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[[vk::constant_id(1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "const bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "= true;") != null);
}

test "M3.3 MSL: bool spec const cross-compiles to [[function_constant(N)]] = true" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_BOOL_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const msl = try glslpp.spirvToMSL(alloc, spv, .{});
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[function_constant(1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "= true;") != null);
}
