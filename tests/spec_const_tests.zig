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

// ── M3.6: SpecOverride API + CLI flag ──

test "M3.6: SpecOverride rewrites int spec const literal" {
    const alloc = std.testing.allocator;
    const overrides = [_]glslpp.SpecOverride{
        .{ .spec_id = 3, .value_u32 = 99 },
    };
    const spv = try glslpp.compileToSPIRVWithSpecOverrides(
        alloc, SHADER_INT_SPEC, .{ .stage = .fragment }, overrides[0..],
    );
    defer alloc.free(spv);
    // Walk for OpSpecConstant (50) whose literal == 99
    var found = false;
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (op == 50 and wc >= 4 and spv[i + 3] == 99) {
            found = true;
            break;
        }
        if (wc == 0) break;
        i += wc;
    }
    try std.testing.expect(found);
}

test "M3.6: SpecOverride swaps bool spec const True <-> False" {
    const alloc = std.testing.allocator;
    // Source declares `ENABLE_FX = true` (SpecId 1). Override to false.
    const overrides = [_]glslpp.SpecOverride{
        .{ .spec_id = 1, .value_u32 = 0 },
    };
    const spv = try glslpp.compileToSPIRVWithSpecOverrides(
        alloc, SHADER_BOOL_SPEC, .{ .stage = .fragment }, overrides[0..],
    );
    defer alloc.free(spv);
    // After override the OpSpecConstantTrue (48) should become OpSpecConstantFalse (49).
    var found_true = false;
    var found_false = false;
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (op == 48) found_true = true;
        if (op == 49) found_false = true;
        if (wc == 0) break;
        i += wc;
    }
    try std.testing.expect(!found_true);
    try std.testing.expect(found_false);
}

test "M3.6: SpecOverride empty list is a no-op (no copy, no leak)" {
    const alloc = std.testing.allocator;
    const empty: []const glslpp.SpecOverride = &.{};
    const spv = try glslpp.compileToSPIRVWithSpecOverrides(
        alloc, SHADER_INT_SPEC, .{ .stage = .fragment }, empty,
    );
    defer alloc.free(spv);
    try std.testing.expect(spv.len > 5);
}

test "M3.6: SpecOverride non-matching spec_id is silently ignored" {
    const alloc = std.testing.allocator;
    const overrides = [_]glslpp.SpecOverride{
        .{ .spec_id = 999, .value_u32 = 0xDEADBEEF },
    };
    const spv = try glslpp.compileToSPIRVWithSpecOverrides(
        alloc, SHADER_INT_SPEC, .{ .stage = .fragment }, overrides[0..],
    );
    defer alloc.free(spv);
    // Original literal 8 should still be present (not 0xDEADBEEF)
    var found_orig = false;
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (op == 50 and wc >= 4 and spv[i + 3] == 8) {
            found_orig = true;
            break;
        }
        if (wc == 0) break;
        i += wc;
    }
    try std.testing.expect(found_orig);
}
