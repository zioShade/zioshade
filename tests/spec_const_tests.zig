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
    // Codegen emits OpName for spec consts so the user-declared identifier
    // (`N`) appears in the output instead of the backend's auto-generated
    // `v{id}` fallback.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "const int N = 8;") != null);
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

// ── M3.4: OpSpecConstantComposite for vec/mat spec consts ──

const SHADER_VEC3_SPEC =
    \\#version 450
    \\layout(constant_id=2) const vec3 TINT = vec3(0.5, 0.5, 0.5);
    \\layout(location=0) out vec4 fragColor;
    \\void main() { fragColor = vec4(TINT, 1.0); }
;

test "M3.4 SPIR-V: vec3 spec const emits OpSpecConstantComposite (op 51)" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, SHADER_VEC3_SPEC, .{ .stage = .fragment });
    defer alloc.free(spirv);
    var found_composite = false;
    var op50_count: usize = 0;
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        const op = spirv[i] & 0xFFFF;
        if (op == 51) found_composite = true;
        if (op == 50) op50_count += 1;
        if (wc == 0) break;
        i += wc;
    }
    try std.testing.expect(found_composite);
    // Three per-scalar OpSpecConstants for the vec3 components.
    try std.testing.expectEqual(@as(usize, 3), op50_count);
}

test "M3.4 SPIR-V: vec3 components decorated with sequential SpecIds (2, 3, 4)" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, SHADER_VEC3_SPEC, .{ .stage = .fragment });
    defer alloc.free(spirv);
    // Walk for OpDecorate ... SpecId N. Expect SpecIds 2, 3, 4 present and 5 absent.
    var seen2 = false;
    var seen3 = false;
    var seen4 = false;
    var seen5 = false;
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        const op = spirv[i] & 0xFFFF;
        if (op == 71 and wc >= 4 and spirv[i + 2] == 1) { // SpecId decoration
            const sid = spirv[i + 3];
            if (sid == 2) seen2 = true;
            if (sid == 3) seen3 = true;
            if (sid == 4) seen4 = true;
            if (sid == 5) seen5 = true;
        }
        if (wc == 0) break;
        i += wc;
    }
    try std.testing.expect(seen2);
    try std.testing.expect(seen3);
    try std.testing.expect(seen4);
    try std.testing.expect(!seen5);
}

test "M3.4 SPIR-V: vec3 component default literal is 0.5 (bit pattern 0x3F000000)" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, SHADER_VEC3_SPEC, .{ .stage = .fragment });
    defer alloc.free(spirv);
    // Walk for OpSpecConstant (50) and check at least one has literal == bits(0.5).
    const expected: u32 = @bitCast(@as(f32, 0.5));
    var found = false;
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        const op = spirv[i] & 0xFFFF;
        if (op == 50 and wc >= 4 and spirv[i + 3] == expected) { found = true; break; }
        if (wc == 0) break;
        i += wc;
    }
    try std.testing.expect(found);
}

test "M3.4 GLSL: vec3 spec const cross-compiles to per-scalar + composite const" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_VEC3_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const glsl = try glslpp.spirvToGLSL(alloc, spv, .{});
    defer alloc.free(glsl);
    // Three per-scalar layout(constant_id) declarations and a vec3 composite.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "layout(constant_id = 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "layout(constant_id = 3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "layout(constant_id = 4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "const vec3") != null);
}

test "M3.4 HLSL: vec3 spec const cross-compiles to per-scalar + static const composite" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_VEC3_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spv, .{ .binding_shift = -1, .shader_model = 60 });
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[[vk::constant_id(2)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[[vk::constant_id(3)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "[[vk::constant_id(4)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "static const float3") != null);
}

test "M3.4 MSL: vec3 spec const cross-compiles to per-scalar [[function_constant]] + composite" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_VEC3_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const msl = try glslpp.spirvToMSL(alloc, spv, .{});
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[function_constant(2)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[function_constant(3)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[function_constant(4)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant float3") != null);
}

test "M3.4 WGSL: vec3 spec const cross-compiles to per-scalar overrides + composite const" {
    const alloc = std.testing.allocator;
    const spv = try glslpp.compileToSPIRV(alloc, SHADER_VEC3_SPEC, .{ .stage = .fragment });
    defer alloc.free(spv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@id(2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@id(3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@id(4)") != null);
    // WGSL emits either `vec3f` (short form) or `vec3<f32>` for vec3<f32>.
    const has_short = std.mem.indexOf(u8, wgsl, "vec3f") != null;
    const has_long = std.mem.indexOf(u8, wgsl, "vec3<f32>") != null;
    try std.testing.expect(has_short or has_long);
    // The composite reassembled as a `const`, not an `override` (WGSL spec
    // requires scalar-typed overrides only).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "const ") != null);
}

const SHADER_VEC4_SPEC =
    \\#version 450
    \\layout(constant_id=10) const vec4 OFFSET = vec4(1.0, 2.0, 3.0, 4.0);
    \\layout(location=0) out vec4 fragColor;
    \\void main() { fragColor = OFFSET; }
;

test "M3.4 SPIR-V: vec4 spec const emits 4 OpSpecConstants + OpSpecConstantComposite" {
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, SHADER_VEC4_SPEC, .{ .stage = .fragment });
    defer alloc.free(spirv);
    var found_composite = false;
    var op50_count: usize = 0;
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        const op = spirv[i] & 0xFFFF;
        if (op == 51) found_composite = true;
        if (op == 50) op50_count += 1;
        if (wc == 0) break;
        i += wc;
    }
    try std.testing.expect(found_composite);
    try std.testing.expectEqual(@as(usize, 4), op50_count);
}

// ── M3.6: SpecOverride non-matching ──

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


// -- M3.5: OpSpecConstantOp for derived spec const expressions ----------

test "M3.5 SPIR-V: int*const emits OpSpecConstantOp" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id=1) const int SIZE = 4;
        \\const int DOUBLE = SIZE * 2;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(DOUBLE)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    var found = false;
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        const op = spirv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == 52) {
            found = true;
            break;
        }
        i += wc;
    }
    try std.testing.expect(found);
}

test "M3.5 SPIR-V: nested expression emits two OpSpecConstantOp" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id=1) const int SIZE = 4;
        \\const int QUAD = SIZE * 2 * 2;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(QUAD)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    var count: u32 = 0;
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        const op = spirv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == 52) count += 1;
        i += wc;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "M3.5 SPIR-V: all four arithmetic ops emit OpSpecConstantOp" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id=1) const int A = 4;
        \\const int ADD = A + 1;
        \\const int SUB = A - 1;
        \\const int MUL = A * 2;
        \\const int DIV = A / 2;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(ADD + SUB + MUL + DIV)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    var count: u32 = 0;
    var i: usize = 5;
    while (i < spirv.len) {
        const wc = spirv[i] >> 16;
        const op = spirv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == 52) count += 1;
        i += wc;
    }
    try std.testing.expect(count >= 4);
}

test "M3.5 GLSL: cross-compile preserves derived const as expression" {
    // Confirm that the GLSL backend renders the binary operator rather than
    // folding to a literal. Codegen now emits OpName for spec consts and
    // for top-level derived spec consts, so the leaf identifier (`SIZE`)
    // and the user-bound derived name (`DOUBLE`) round-trip through the
    // backend.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id=1) const int SIZE = 4;
        \\const int DOUBLE = SIZE * 2;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(DOUBLE)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{});
    defer alloc.free(glsl);
    // Leaf spec const declared with user identifier preserved.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "layout(constant_id = 1) const int SIZE = 4") != null);
    // Derived const rendered as an expression, not folded.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "*") != null);
    // User-facing derived identifier preserved.
    try std.testing.expect(std.mem.indexOf(u8, glsl, "DOUBLE") != null);
}

// ── OpName for spec consts: original GLSL identifiers preserved everywhere ──

test "spec const: original GLSL name preserved across all backends" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id=1) const int MY_SIZE = 8;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(MY_SIZE)); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);

    // GLSL
    {
        const out = try glslpp.spirvToGLSL(alloc, spv, .{});
        defer alloc.free(out);
        if (std.mem.indexOf(u8, out, "MY_SIZE") == null) {
            std.debug.print("GLSL backend missing MY_SIZE:\n{s}\n", .{out});
            try std.testing.expect(false);
        }
    }
    // HLSL
    {
        const out = try glslpp.spirvToHLSL(alloc, spv, .{ .shader_model = 60 });
        defer alloc.free(out);
        if (std.mem.indexOf(u8, out, "MY_SIZE") == null) {
            std.debug.print("HLSL backend missing MY_SIZE:\n{s}\n", .{out});
            try std.testing.expect(false);
        }
    }
    // MSL
    {
        const out = try glslpp.spirvToMSL(alloc, spv, .{});
        defer alloc.free(out);
        if (std.mem.indexOf(u8, out, "MY_SIZE") == null) {
            std.debug.print("MSL backend missing MY_SIZE:\n{s}\n", .{out});
            try std.testing.expect(false);
        }
    }
    // WGSL
    {
        const out = try glslpp.spirvToWGSL(alloc, spv, .{});
        defer alloc.free(out);
        if (std.mem.indexOf(u8, out, "MY_SIZE") == null) {
            std.debug.print("WGSL backend missing MY_SIZE:\n{s}\n", .{out});
            try std.testing.expect(false);
        }
    }
}

test "spec const: derived user-bound name preserved across all backends" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id=1) const int SIZE = 4;
        \\const int DOUBLE_SIZE = SIZE * 2;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(DOUBLE_SIZE)); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);

    // GLSL
    {
        const out = try glslpp.spirvToGLSL(alloc, spv, .{});
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "SIZE") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "DOUBLE_SIZE") != null);
    }
    // HLSL
    {
        const out = try glslpp.spirvToHLSL(alloc, spv, .{ .shader_model = 60 });
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "SIZE") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "DOUBLE_SIZE") != null);
    }
    // MSL
    {
        const out = try glslpp.spirvToMSL(alloc, spv, .{});
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "SIZE") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "DOUBLE_SIZE") != null);
    }
    // WGSL
    {
        const out = try glslpp.spirvToWGSL(alloc, spv, .{});
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "SIZE") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "DOUBLE_SIZE") != null);
    }
}

// ── M3.4 bounds check: composite spec-const default literals > 0xFFFFFFFF ──
//
// The M3.4 composite default-value extraction in collectTopLevel reads
// constructor argument literals directly from the AST. For a literal whose
// magnitude exceeds 32 bits (e.g. `uvec2(5000000000u, 1u)`), the int-element
// path used `@truncate` and SILENTLY produced a wrong component word
// (5000000000 → 705032704); the float-element path used `@floatFromInt` and
// silently accepted the out-of-range literal. glslangValidator rejects both
// with "numeric literal too big", so glslpp must record an honest error
// (error.SemanticFailed) rather than emit a silent-wrong constant.

/// Collect every OpSpecConstant (op 50) 32-bit literal value from a SPIR-V blob.
fn collectSpecConstLiterals(alloc: std.mem.Allocator, spv: []const u32) ![]u32 {
    var lits = std.ArrayListUnmanaged(u32).empty;
    errdefer lits.deinit(alloc);
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == 50 and wc >= 4) try lits.append(alloc, spv[i + 3]);
        i += wc;
    }
    return lits.toOwnedSlice(alloc);
}

test "M3.4 spec const: uvec2 component literal > 0xFFFFFFFF is an honest error, not silent truncation" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id = 0) const uvec2 V = uvec2(5000000000u, 1u);
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(V.x), float(V.y), 0.0, 1.0); }
    ;
    // Oracle (glslangValidator -V): "numeric literal too big". glslpp must
    // reject too — the silent-truncation path turned 5000000000 into 705032704.
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment }),
    );
}

test "M3.4 spec const: vec2 int-element literal > 0xFFFFFFFF is an honest error (float path)" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id = 0) const vec2 V = vec2(5000000000);
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(V, 0.0, 1.0); }
    ;
    // Oracle rejects with "numeric literal too big". The float-element branch
    // (@floatFromInt) previously accepted the out-of-32-bit literal silently.
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment }),
    );
}

test "M3.4 spec const: in-range uvec2(7u, 8u) components emit correct literals 7 and 8" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id = 0) const uvec2 V = uvec2(7u, 8u);
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(V.x), float(V.y), 0.0, 1.0); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const lits = try collectSpecConstLiterals(alloc, spv);
    defer alloc.free(lits);
    try std.testing.expect(std.mem.indexOfScalar(u32, lits, 7) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, lits, 8) != null);
    // The silently-truncated value must NOT appear.
    try std.testing.expect(std.mem.indexOfScalar(u32, lits, 705032704) == null);
}

test "M3.4 spec const: in-range ivec3(1, 2, 3) components emit correct literals 1, 2, 3" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id = 0) const ivec3 I = ivec3(1, 2, 3);
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(I.x), float(I.y), float(I.z), 1.0); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const lits = try collectSpecConstLiterals(alloc, spv);
    defer alloc.free(lits);
    try std.testing.expect(std.mem.indexOfScalar(u32, lits, 1) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, lits, 2) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, lits, 3) != null);
}

test "M3.4 spec const: in-range vec2(3, 4) int args convert to float component literals 3.0 and 4.0" {
    // Exercises the float-element branch (@floatFromInt(word)) with in-range
    // integer constructor arguments, pinning that routing through literalWord
    // did not change the correct conversion for valid literals.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id = 0) const vec2 V = vec2(3, 4);
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(V, 0.0, 1.0); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const lits = try collectSpecConstLiterals(alloc, spv);
    defer alloc.free(lits);
    const f3: u32 = @bitCast(@as(f32, 3.0));
    const f4: u32 = @bitCast(@as(f32, 4.0));
    try std.testing.expect(std.mem.indexOfScalar(u32, lits, f3) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, lits, f4) != null);
}

test "M3.4 spec const: scalar uint default > 0xFFFFFFFF is an honest error (scalar path guard)" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(constant_id = 0) const uint N = 5000000000u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(float(N)); }
    ;
    // The scalar path routes through analyzeExpression → literalWord, so it is
    // already guarded; this test pins that behavior against regressions.
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment }),
    );
}
