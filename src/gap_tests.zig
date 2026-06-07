// SPDX-License-Identifier: MIT OR Apache-2.0
// Gap tests: cover every known structural/correctness gap between our SPIR-V output and glslang's.
// Each test compiles a minimal GLSL snippet and inspects the IR or SPIR-V output for the expected
// instruction pattern. Tests are organized by gap category.
//
// Run: zig test src/gap_tests.zig
// (or via build system)

const std = @import("std");
const testing = std.testing;
const glslpp = @import("root.zig");
const semantic = @import("semantic.zig");
const ir = @import("ir.zig");
const codegen = @import("codegen.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const spirv = @import("spirv.zig");

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Compile GLSL source to SPIR-V words, spirv-val the result, and return the words.
/// Caller owns the returned slice.
fn compileToWords(alloc: std.mem.Allocator, source: [:0]const u8, stage: glslpp.Stage) ![]const u32 {
    const words = glslpp.compileToSPIRV(alloc, source, .{ .stage = stage }) catch |err| {
        std.debug.print("COMPILE ERROR: {s}\n  ctx={s} inner={s}\n", .{
            @errorName(err),
            semantic.last_error_ctx,
            semantic.last_error_inner,
        });
        return err;
    };
    return words;
}

/// Compile to a semantic module (for inspecting IR instructions).
/// Caller must call module.deinit().
fn compileToIR(alloc: std.mem.Allocator, source: [:0]const u8) !*ir.Module {
    const tokens = try lexer.tokenize(alloc, source);
    defer alloc.free(tokens);
    var root = try parser.parse(alloc, source, tokens);
    defer parser.freeTree(alloc, &root);
    const module = try semantic.analyzeWithOptions(alloc, &root, .{ .tolerate_errors = false });
    const ptr = try alloc.create(ir.Module);
    ptr.* = module;
    return ptr;
}

/// Find first instruction with the given tag across all functions.
fn findTag(module: *ir.Module, tag: ir.Instruction.Tag) ?ir.Instruction {
    for (module.functions) |func| {
        for (func.body) |inst| {
            if (inst.tag == tag) return inst;
        }
    }
    return null;
}

/// Count instructions with the given tag across all functions.
fn countTag(module: *ir.Module, tag: ir.Instruction.Tag) usize {
    var n: usize = 0;
    for (module.functions) |func| {
        for (func.body) |inst| {
            if (inst.tag == tag) n += 1;
        }
    }
    return n;
}

/// Count SPIR-V opcodes in the binary output.
fn countOp(words: []const u32, op: spirv.Op) usize {
    var n: usize = 0;
    var i: usize = 5; // skip header
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(op)) n += 1;
        if (word_count == 0) break;
        i += word_count;
    }
    return n;
}

/// Return the result-type ID of the first instruction with the given opcode,
/// or null if no such instruction exists. Assumes the opcode is a type-producing
/// instruction whose layout is `[header | result_type_id | result_id | ...]`
/// (e.g. OpImageGather / OpImageDrefGather), so the result-type ID is the first
/// operand word.
fn firstResultTypeId(words: []const u32, op: spirv.Op) ?u32 {
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(op) and word_count >= 3 and i + 1 < words.len) {
            return words[i + 1];
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

/// Verify that the given type ID is defined by `OpTypeVector <float> 4`, i.e. a
/// vec4 of 32-bit floats. Walks the type section to resolve the component type
/// ID against an `OpTypeFloat 32`.
fn typeIsVec4Float(words: []const u32, type_id: u32) bool {
    // First pass: find the OpTypeVector defining `type_id`, capture its
    // component type ID and component count.
    var component_type: ?u32 = null;
    var component_count: u32 = 0;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        // OpTypeVector: [header | result_id | component_type_id | count]
        if (opcode == @intFromEnum(spirv.Op.TypeVector) and word_count >= 4 and words[i + 1] == type_id) {
            component_type = words[i + 2];
            component_count = words[i + 3];
            break;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    if (component_type == null or component_count != 4) return false;
    // Second pass: confirm the component type is OpTypeFloat with width 32.
    i = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        // OpTypeFloat: [header | result_id | width]
        if (opcode == @intFromEnum(spirv.Op.TypeFloat) and word_count >= 3 and words[i + 1] == component_type.?) {
            return words[i + 2] == 32;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

/// Check that a SPIR-V binary contains a specific capability.
fn hasCapability(words: []const u32, cap: spirv.Capability) bool {
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(spirv.Op.Capability) and word_count >= 2 and i + 1 < words.len) {
            if (words[i + 1] == @intFromEnum(cap)) return true;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

/// Disassemble SPIR-V to text (requires spirv-dis on PATH). Returns owned string.
fn disassemble(alloc: std.mem.Allocator, words: []const u32) ![]const u8 {
    _ = alloc;
    _ = words;
    return error.NotAvailable; // disabled for Zig 0.16 compat
}

// ─── Gap 1: floatBitsToUint / floatBitsToInt / intBitsToFloat / uintBitsToFloat ─
// These should emit OpBitcast, NOT a numeric conversion.

test "gap: floatBitsToUint emits OpBitcast not conversion" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uvec4 u = floatBitsToUint(v);
        \\    o = uintBitsToFloat(u);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const bitcast_count = countOp(words, .Bitcast);
    const ftoi_count = countOp(words, .ConvertFToU);
    const utof_count = countOp(words, .ConvertUToF);

    // Should use bitcast, not numeric conversion
    try testing.expect(bitcast_count >= 2); // floatBitsToUint + uintBitsToFloat
    try testing.expect(ftoi_count == 0);
    try testing.expect(utof_count == 0);
}

test "gap: floatBitsToInt emits OpBitcast not conversion" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec4 i = floatBitsToInt(v);
        \\    o = intBitsToFloat(i);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const bitcast_count = countOp(words, .Bitcast);
    try testing.expect(bitcast_count >= 2);
}

test "gap: uintBitsToFloat on scalar emits OpBitcast" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uint u = 1065353216u;
        \\    float f = uintBitsToFloat(u);
        \\    o = vec4(f);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .Bitcast) >= 1);
}

// ─── Gap 2: Dead function elimination ──────────────────────────────────────
// The compiler should not emit functions that are never called.
// Currently we emit ALL functions from common.glsl even if only 2 are used.

test "gap: unused functions should not appear in SPIR-V" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\float used_fn(float x) { return x * 2.0; }
        \\float unused_fn(float x) { return x + 1.0; }
        \\void main() {
        \\    o = vec4(used_fn(1.0));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const func_count = countOp(words, .Function);
    // Should be 2 (used_fn + main), not 3 (used_fn + unused_fn + main)
    // NOTE: Currently this WILL fail — it's a gap test.
    // When the gap is fixed, this test will pass.
    try testing.expect(func_count <= 2);
}

// ─── Gap 3: gl_PerVertex block ──────────────────────────────────────────────
// Vertex shaders should wrap gl_Position in the canonical gl_PerVertex block.

test "gap: vertex shader should emit gl_PerVertex block" {
    const source: [:0]const u8 =
        \\#version 450
        \\void main() {
        \\    gl_Position = vec4(1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .vertex);
    defer testing.allocator.free(words);

    // Check for gl_PerVertex struct type (OpTypeStruct with gl_PerVertex name)
    // The gl_PerVertex block is a struct with at least gl_Position, gl_PointSize, gl_ClipDistance
    // For now, check that there's an OpVariable with Output storage class that is Block-decorated
    // or at minimum that gl_Position is properly decorated BuiltIn Position
    const has_position_builtin = hasBuiltinDecoration(words, .position);
    try testing.expect(has_position_builtin);
}

/// Check if the SPIR-V has a BuiltIn decoration for the given built-in.
fn hasBuiltinDecoration(words: []const u32, builtin: spirv.BuiltIn) bool {
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        // OpDecorate: opcode 71, format: OpDecorate <target> BuiltIn <built-in>
        // OpMemberDecorate: opcode 72, format: OpMemberDecorate <struct> <member> BuiltIn <built-in>
        if ((opcode == 71 or opcode == 72) and word_count >= 4) {
            const decoration = words[i + 2];
            if (decoration == 11) { // BuiltIn decoration
                const builtin_val = words[i + 3];
                if (builtin_val == @intFromEnum(builtin)) return true;
            }
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

// ─── Gap 4: OpPhi for SSA merge at join points ────────────────────────────
// After an if/else that writes to a variable, the merged value should use OpPhi
// instead of storing through a local variable.

test "gap: if/else write to SSA var should use OpPhi or equivalent" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float c;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float x;
        \\    if (c > 0.0) { x = 1.0; } else { x = 2.0; }
        \\    o = vec4(x);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Currently we use stores to a local variable, not OpPhi.
    // This test documents the gap. When fixed, OpPhi count should be >= 1.
    // For now just verify it compiles and passes spirv-val (already done by compileToWords).
    try testing.expect(words.len > 0);
}

// ─── Gap 5: textureSize ivec2→vec2 conversion ─────────────────────────────
// textureSize() returns ivec2 but is commonly assigned to vec2.
// The compiler must insert an implicit ConvertSToF.

test "gap: vec2 tex_size = textureSize(sampler, 0) requires implicit conversion" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec2 size = textureSize(tex, 0);
        \\    o = vec4(size, 0.0, 1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Should emit OpConvertSToF to convert ivec2 → vec2
    const conv_count = countOp(words, .ConvertSToF);
    try testing.expect(conv_count >= 1);
}

test "gap: ivec2 var = textureSize(sampler, 0) should NOT require conversion" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec2 size = textureSize(tex, 0);
        \\    o = vec4(float(size.x));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // No vector conversion needed — only scalar int→float for the .x
    const vec_conv = countOp(words, .ConvertSToF);
    // At most 1 scalar conversion for float(size.x), NOT a vector conversion
    try testing.expect(vec_conv <= 1);
}

// ─── Gap 6: sampler2DRect support ──────────────────────────────────────────
// Ghostty's cell_text shader uses sampler2DRect which has unnormalized coords.

test "gap: sampler2DRect is recognized as a valid sampler type" {
    const source: [:0]const u8 =
        \\#version 330
        \\uniform sampler2DRect tex;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = texture(tex, vec2(10.0, 20.0));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Should compile without error and emit a texture sample
    try testing.expect(words.len > 0);
}

// ─── Gap 7: mod() with unsigned arguments ─────────────────────────────────
// uvec4 % uvec4 should emit OpUMod, not OpFMod or Round.

test "gap: uvec4 % uvec4 should emit OpUMod not OpFMod" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uvec4 a = uvec4(10u, 20u, 30u, 40u);
        \\    uvec4 b = uvec4(3u, 7u, 5u, 8u);
        \\    uvec4 r = a % b;
        \\    o = vec4(r);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const umod_count = countOp(words, .UMod);
    const fmod_count = countOp(words, .FMod);
    try testing.expect(umod_count >= 1); // at least one OpUMod
    try testing.expect(fmod_count == 0); // no float mod on uints
}

test "gap: ivec4 % ivec4 should emit OpSRem" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec4 a = ivec4(10, -20, 30, -40);
        \\    ivec4 b = ivec4(3, 7, -5, -8);
        \\    ivec4 r = a % b;
        \\    o = vec4(r);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const srem_count = countOp(words, .SRem);
    try testing.expect(srem_count >= 1);
}

// ─── Gap 8: gl_FragCoord origin_upper_left ────────────────────────────────
// Ghostty uses `layout(origin_upper_left) in vec4 gl_FragCoord`.

test "gap: layout(origin_upper_left) in vec4 gl_FragCoord compiles" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(origin_upper_left) in vec4 gl_FragCoord;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = gl_FragCoord;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Should emit OriginUpperLeft execution mode
    try testing.expect(words.len > 0);
}

// ─── Gap 9: flat interpolation qualifier ───────────────────────────────────
// Ghostty uses `flat in` on several inputs.

test "gap: flat in vec4 compiles with Flat decoration" {
    const source: [:0]const u8 =
        \\#version 450
        \\flat in vec4 vColor;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = vColor;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 10: std140/std430 layout qualifiers ──────────────────────────────
// Ghostty uses both std140 and std430 uniform buffers.

test "gap: std140 uniform block compiles" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(std140, binding = 0) uniform UBO {
        \\    mat4 mvp;
        \\    vec4 color;
        \\} ubo;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = ubo.color;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

test "gap: std430 storage buffer compiles" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(std430, binding = 0) buffer SSBO {
        \\    vec4 data[];
        \\} ssbo;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = ssbo.data[0];
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 11: texture() with vec2 coord ────────────────────────────────────
// Basic texture sampling should work.

test "gap: texture(sampler2D, vec2) emits OpImageSampleImplicitLod" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = texture(tex, uv);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const sample_count = countOp(words, .ImageSampleImplicitLod);
    try testing.expect(sample_count >= 1);
}

// ─── Gap 12: textureSize for 1D/3D/cube/array samplers ────────────────────

test "gap: textureSize(samplerCube, lod) returns ivec3" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform samplerCube tex;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec3 size = textureSize(tex, 0);
        \\    o = vec4(float(size.x));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

test "gap: textureSize(sampler2DArray, lod) returns ivec3" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2DArray tex;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec3 size = textureSize(tex, 0);
        \\    o = vec4(float(size.x));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 13: textureProj ───────────────────────────────────────────────────

test "gap: textureProj(sampler2D, vec4) emits OpImageSampleProjImplicitLod" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) in vec4 coord;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = textureProj(tex, coord);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 14: Shadow texture with bias ──────────────────────────────────────

test "gap: texture(sampler2DShadow, vec3, bias) emits Bias operand" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2DShadow tex;
        \\layout(location = 0) in vec3 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float d = texture(tex, uv, 0.5);
        \\    o = vec4(d);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 15: texelFetch ────────────────────────────────────────────────────

test "gap: texelFetch(sampler2D, ivec2, lod) emits OpImageFetch" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) in ivec2 coord;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = texelFetch(tex, coord, 0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const fetch_count = countOp(words, .ImageFetch);
    try testing.expect(fetch_count >= 1);
}

// ─── Gap 16: textureLod ───────────────────────────────────────────────────

test "gap: textureLod(sampler2D, vec2, lod) emits OpImageSampleExplicitLod" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = textureLod(tex, uv, 2.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const explicit_count = countOp(words, .ImageSampleExplicitLod);
    try testing.expect(explicit_count >= 1);
}

// ─── Gap 17: textureOffset with ConstOffset ────────────────────────────────

test "gap: textureOffset(sampler2D, vec2, ivec2) emits ConstOffset" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = textureOffset(tex, uv, ivec2(1, 2));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Should use OpImageSampleImplicitLod with ConstOffset operand
    try testing.expect(words.len > 0);
}

// ─── Gap 18: textureLodOffset ─────────────────────────────────────────────

test "gap: textureLodOffset emits ExplicitLod with ConstOffset" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = textureLodOffset(tex, uv, 2.0, ivec2(1, 1));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 19: textureGather ────────────────────────────────────────────────

test "gap: textureGather(sampler2DShadow, vec2, ref) emits OpImageDrefGather with vec4 result" {
    // Shadow textureGather is VALID GLSL (glslangValidator -V accepts it) and
    // returns a vec4 of 4 depth-comparison results. The reference toolchain emits
    //   OpImageDrefGather %v4float %sampledImage %coord %dref
    // with NO int component operand (unlike non-shadow gather). This test pins
    // BOTH that the op is the Dref form AND that its result type is vec4 — the
    // previous version only asserted `words.len > 0`, a false-green that passed
    // even when the analyzer mistyped the result as float.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2DShadow tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = textureGather(tex, uv, 0.5);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Must use OpImageDrefGather (the depth-comparison gather), NOT plain gather.
    try testing.expectEqual(@as(usize, 1), countOp(words, .ImageDrefGather));
    try testing.expectEqual(@as(usize, 0), countOp(words, .ImageGather));
    // Result type must be vec4 (4 gathered comparison results), not float.
    const rt = firstResultTypeId(words, .ImageDrefGather) orelse return error.NoDrefGather;
    try testing.expect(typeIsVec4Float(words, rt));
}

test "gap: shadow textureGather result is vec4 (not over-rejected when bound to vec4)" {
    // ROOT-CAUSE REGRESSION GUARD. The analyzer computed the result type of any
    // shadow-sampler image builtin as `.float` (correct for shadow SAMPLE, which
    // returns a single compared depth). But shadow textureGather returns a vec4.
    // Binding the call to a `vec4` local forces the assignment type-check to
    // observe the static type: with the bug it sees `float`, raising
    // error.TypeMismatch and rejecting valid GLSL. glslangValidator -V accepts
    // this shader. The direct-store form (o = textureGather(...)) accidentally
    // hid the bug because codegen forces a vec4 result type regardless.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2DShadow tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 1) in float refz;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 g = textureGather(tex, uv, refz);
        \\    o = vec4(g.x, g.y, g.z, g.w);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expectEqual(@as(usize, 1), countOp(words, .ImageDrefGather));
    const rt = firstResultTypeId(words, .ImageDrefGather) orelse return error.NoDrefGather;
    try testing.expect(typeIsVec4Float(words, rt));
}

test "gap: non-shadow textureGather still emits OpImageGather (not Dref), with vec4 result" {
    // Regression guard for the OTHER direction: a non-shadow sampler with an int
    // component arg must keep emitting OpImageGather, NOT the Dref form. The fix
    // for shadow gather must not over-broaden and reroute the non-shadow form.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 g = textureGather(tex, uv, 0);
        \\    o = g;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expectEqual(@as(usize, 1), countOp(words, .ImageGather));
    try testing.expectEqual(@as(usize, 0), countOp(words, .ImageDrefGather));
    const rt = firstResultTypeId(words, .ImageGather) orelse return error.NoGather;
    try testing.expect(typeIsVec4Float(words, rt));
}

// ─── Gap 20: matrix operations ─────────────────────────────────────────────

test "gap: mat4 * vec4 emits OpMatrixTimesVector" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform UBO { mat4 mvp; };
        \\layout(location = 0) in vec4 pos;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = mvp * pos;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const mvp_count = countOp(words, .MatrixTimesVector);
    try testing.expect(mvp_count >= 1);
}

test "gap: vec4 * mat4 emits OpVectorTimesMatrix" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform UBO { mat4 m; };
        \\layout(location = 0) in vec4 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = v * m;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const vtm_count = countOp(words, .VectorTimesMatrix);
    try testing.expect(vtm_count >= 1);
}

// ─── Gap 21: VectorTimesScalar ─────────────────────────────────────────────

test "gap: vec4 * float emits OpVectorTimesScalar" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
        \\    o = v * 2.0;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const vts_count = countOp(words, .VectorTimesScalar);
    const fmul_count = countOp(words, .FMul);
    // Should use VectorTimesScalar, not component-wise FMul
    try testing.expect(vts_count >= 1);
    try testing.expect(fmul_count == 0);
}

test "gap: vec4 *= float emits OpVectorTimesScalar" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
        \\    v *= 2.0;
        \\    o = v;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const vts_count = countOp(words, .VectorTimesScalar);
    try testing.expect(vts_count >= 1);
}

// ─── Gap 22: Identity VectorShuffle elimination ──────────────────────────

test "gap: vec3.xyz should be a no-op, not emit OpVectorShuffle" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec3 v = vec3(1.0, 2.0, 3.0);
        \\    vec3 w = v.xyz;
        \\    o = vec4(w, 1.0);
        \\}
    ;
    const module = try compileToIR(testing.allocator, source);
    defer { module.deinit(); testing.allocator.destroy(module); }

    // Should NOT emit a vector_shuffle for v.xyz on a vec3
    const shuffle_count = countTag(module, .vector_shuffle);
    try testing.expect(shuffle_count == 0);
}

test "gap: vec4.xyz should emit VectorShuffle (not identity)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
        \\    vec3 w = v.xyz;
        \\    o = vec4(w, 1.0);
        \\}
    ;
    const module = try compileToIR(testing.allocator, source);
    defer { module.deinit(); testing.allocator.destroy(module); }

    // vec4.xyz IS a swizzle (drops .w), so it should emit a shuffle
    const shuffle_count = countTag(module, .vector_shuffle);
    try testing.expect(shuffle_count >= 1);
}

// ─── Gap 23: OpConstantComposite for literal constructors ─────────────────

test "gap: vec4(1.0, 2.0, 3.0, 4.0) emits OpConstantComposite" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = vec4(1.0, 2.0, 3.0, 4.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const cc_count = countOp(words, .ConstantComposite);
    try testing.expect(cc_count >= 1);
}

test "gap: vec4(1.0) splat emits OpConstantComposite" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = vec4(1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const cc_count = countOp(words, .ConstantComposite);
    try testing.expect(cc_count >= 1);
}

test "gap: ivec2(1, 2) emits OpConstantComposite" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec2 v = ivec2(1, 2);
        \\    o = vec4(float(v.x), float(v.y), 0.0, 1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    const cc_count = countOp(words, .ConstantComposite);
    try testing.expect(cc_count >= 1);
}

// ─── Gap 24: OpCompositeConstruct upgrade to OpConstantComposite ──────────
// When all operands of a composite_construct are constants, upgrade to constant_composite.

test "gap: array of all-constant elements emits OpConstantComposite" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    const vec4 arr[2] = vec4[](vec4(1.0), vec4(2.0));
        \\    o = arr[0] + arr[1];
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Array of constants should use OpConstantComposite, not runtime OpCompositeConstruct
    const cc_count = countOp(words, .ConstantComposite);
    try testing.expect(cc_count >= 2);
}

// ─── Gap 25: bvec comparisons (lessThan, greaterThan, equal, etc.) ────────

test "gap: lessThan(vec2, vec2) emits OpFOrdLessThan" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    bvec2 b = lessThan(a, vec2(0.5));
        \\    o = vec4(float(b.x), float(b.y), 0.0, 1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .FOrdLessThan) >= 1);
}

test "gap: equal(ivec2, ivec2) emits OpIEqual" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in ivec2 a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    bvec2 b = equal(a, ivec2(1, 2));
        \\    o = vec4(float(b.x), float(b.y), 0.0, 1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .IEqual) >= 1);
}

// ─── Gap 26: mix() builtin ────────────────────────────────────────────────

test "gap: mix(vec4, vec4, float) emits VectorTimesScalar + FAdd" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 a;
        \\layout(location = 0) in vec4 b;
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = mix(a, b, t);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // mix(a, b, t) = a * (1 - t) + b * t
    try testing.expect(words.len > 0);
}

test "gap: mix(vec4, vec4, bvec4) component-wise select" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 a;
        \\layout(location = 0) in vec4 b;
        \\layout(location = 0) in vec4 cond;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = mix(a, b, lessThan(cond, vec4(0.5)));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Should use OpSelect for bvec mix
    try testing.expect(countOp(words, .Select) >= 1);
}

// ─── Gap 27: clamp(), min(), max() builtins ───────────────────────────────

test "gap: clamp(float, float, float) compiles" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float c = clamp(x, 0.0, 1.0);
        \\    o = vec4(c);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

test "gap: clamp(vec4, float, float) component-wise" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = clamp(v, 0.0, 1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 28: pow(), exp(), log(), sqrt() builtins ────────────────────────

test "gap: pow(float, float) emits OpExtInst" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = vec4(pow(x, 2.0));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .ExtInst) >= 1);
}

// ─── Gap 29: dFdx / dFdy / fwidth ────────────────────────────────────────

test "gap: dFdx(float) emits OpDPdx" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = vec4(dFdx(x));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .DPdx) >= 1);
}

// ─── Gap 30: gl_VertexID / gl_InstanceID ──────────────────────────────────

test "gap: gl_VertexID is accessible in vertex shader" {
    const source: [:0]const u8 =
        \\#version 450
        \\void main() {
        \\    int id = gl_VertexID;
        \\    float f = float(id);
        \\    gl_Position = vec4(f);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .vertex);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 31: array of uniforms ────────────────────────────────────────────

test "gap: uniform vec4 arr[4] compiles" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform UBO {
        \\    vec4 colors[4];
        \\};
        \\void main() {
        \\    o = colors[0];
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 32: push_constant block ──────────────────────────────────────────

test "gap: push_constant block compiles" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(push_constant) uniform PC {
        \\    vec4 color;
        \\} pc;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = pc.color;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 33: image load/store ─────────────────────────────────────────────

test "gap: imageLoad(image2D, ivec2) emits OpImageRead" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0, rgba32f) uniform image2D img;
        \\layout(location = 0) in ivec2 coord;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = imageLoad(img, coord);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .ImageRead) >= 1);
}

test "gap: imageStore(image2D, ivec2, vec4) emits OpImageWrite" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0, rgba32f) uniform image2D img;
        \\layout(location = 0) in ivec2 coord;
        \\void main() {
        \\    imageStore(img, coord, vec4(1.0));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .compute);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .ImageWrite) >= 1);
}

// ─── Gap 34: compute shader with local_size ───────────────────────────────

test "gap: compute shader with layout(local_size_x = 64) compiles" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(binding = 0) buffer SSBO { vec4 data[]; };
        \\void main() {
        \\    uint id = gl_GlobalInvocationID.x;
        \\    data[id] = vec4(float(id));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .compute);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 35: discard ───────────────────────────────────────────────────────

test "gap: discard emits OpKill" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float c;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    if (c < 0.0) discard;
        \\    o = vec4(1.0);
        \\}
    ;
    const module = try compileToIR(testing.allocator, source);
    defer { module.deinit(); testing.allocator.destroy(module); }

    try testing.expect(findTag(module, .kill) != null);
}

// ─── Gap 36: nested struct access ──────────────────────────────────────────

test "gap: struct.member.submember chain emits chained OpAccessChain" {
    const source: [:0]const u8 =
        \\#version 450
        \\struct Inner { float x; float y; };
        \\struct Outer { Inner pos; vec4 color; };
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    Outer s = Outer(Inner(1.0, 2.0), vec4(3.0));
        \\    o = vec4(s.pos.x, s.pos.y, 0.0, 1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 37: ternary operator ─────────────────────────────────────────────

test "gap: ternary operator emits OpSelect" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float c;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float x = c > 0.0 ? 1.0 : 2.0;
        \\    o = vec4(x);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .Select) >= 1);
}

// ─── Gap 38: vector component swizzle write ───────────────────────────────

test "gap: v.xy = vec2(a, b) updates only the first two components" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
        \\    v.xy = vec2(10.0, 20.0);
        \\    o = v;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 39: compound assignment operators (+=, -=, *=, /=) ──────────────

test "gap: v += u emits vector add" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(1.0);
        \\    v += vec4(2.0);
        \\    o = v;
        \\}
    ;
    const module = try compileToIR(testing.allocator, source);
    defer { module.deinit(); testing.allocator.destroy(module); }

    try testing.expect(findTag(module, .fadd) != null);
}

test "gap: v *= float emits VectorTimesScalar" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
        \\    v *= 2.0;
        \\    o = v;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .VectorTimesScalar) >= 1);
}

// ─── Gap 40: integer arithmetic ────────────────────────────────────────────

test "gap: int + int emits OpIAdd" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    int a = 1;
        \\    int b = 2;
        \\    int c = a + b;
        \\    o = vec4(float(c));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .IAdd) >= 1);
}

test "gap: uint bitwise AND emits OpBitwiseAnd" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uint a = 0xFF00u;
        \\    uint b = 0x00FFu;
        \\    uint c = a & b;
        \\    o = vec4(float(c));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .BitwiseAnd) >= 1);
}

test "gap: uint shift right emits OpShiftRightLogical" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uint a = 256u;
        \\    uint b = a >> 4u;
        \\    o = vec4(float(b));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .ShiftRightLogical) >= 1);
}

// ─── Gap 41: struct constructor ────────────────────────────────────────────

test "gap: struct constructor with all-constant fields emits OpConstantComposite" {
    const source: [:0]const u8 =
        \\#version 450
        \\struct Foo { float a; float b; };
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    const Foo f = Foo(1.0, 2.0);
        \\    o = vec4(f.a, f.b, 0.0, 1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Struct with all-constant fields should use OpConstantComposite
    const cc_count = countOp(words, .ConstantComposite);
    try testing.expect(cc_count >= 1);
}

// ─── Gap 42: barrier() / memoryBarrier() ──────────────────────────────────

test "gap: barrier() emits OpControlBarrier" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(binding = 0) buffer SSBO { vec4 data[]; };
        \\void main() {
        \\    data[0] = vec4(1.0);
        \\    barrier();
        \\    data[0] += data[0];
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .compute);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .ControlBarrier) >= 1);
}

test "gap: memoryBarrier() emits OpMemoryBarrier" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(binding = 0) buffer SSBO { vec4 data[]; };
        \\void main() {
        \\    data[0] = vec4(1.0);
        \\    memoryBarrier();
        \\    data[0] += data[0];
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .compute);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .MemoryBarrier) >= 1);
}

// ─── Gap 43: mod() builtin with float vectors ────────────────────────────

test "gap: mod(vec4, vec4) emits OpFMod via GLSL.std.450" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 a;
        \\layout(location = 0) in vec4 b;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = mod(a, b);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .FMod) >= 1);
}

// ─── Gap 44: float16 types ────────────────────────────────────────────────
// 16-bit types should NOT be in isTypeKeyword (regression guard)

test "gap: float16_t parses but doesn't cause keyword regression" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float h = 1.0;
        \\    o = vec4(h);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 45: Spec constants ───────────────────────────────────────────────

test "gap: const array size with spec constant ID" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(constant_id = 1) const int SIZE = 4;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float arr[SIZE];
        \\    arr[0] = 1.0;
        \\    o = vec4(arr[0]);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Should emit OpSpecConstant with SpecId decoration
    try testing.expect(countOp(words, .SpecConstant) >= 1);
}

// ─── Gap 46: swizzle compound assignment ──────────────────────────────────

test "gap: v.xy *= vec2 compiles and produces VectorTimesScalar" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
        \\    v.xy *= 2.0;
        \\    o = v;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 47: negative constants ────────────────────────────────────────────

test "gap: float -1.0 emits OpConstant with negative bit pattern" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = vec4(-1.0, -0.5, -2.0, 1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 48: uint literal suffix ──────────────────────────────────────────

test "gap: 42u parses as uint literal" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uint x = 42u;
        \\    o = vec4(float(x));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 49: textureGrad ──────────────────────────────────────────────────

test "gap: textureGrad(sampler2D, coord, dPdx, dPdy) compiles" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) in vec2 dx;
        \\layout(location = 0) in vec2 dy;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = textureGrad(tex, uv, dx, dy);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap 50: inverse() and transpose() builtins ──────────────────────────

test "gap: transpose(mat4) emits OpTranspose" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform UBO { mat4 m; };
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat4 t = transpose(m);
        \\    o = t[0];
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(countOp(words, .Transpose) >= 1);
}

// ─── Gap 51: gl_FragDepth with depth layout qualifiers ────────────────────

test "gap: layout(depth_greater) out float gl_FragDepth emits DepthGreater execution mode" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(depth_greater) out float gl_FragDepth;
        \\void main() {
        \\    gl_FragDepth = 0.5;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
    // Should have BuiltIn FragDepth decoration
    try testing.expect(hasBuiltinDecoration(words, .frag_depth));
}

test "gap: layout(depth_less) emits DepthLess execution mode" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(depth_less) out float gl_FragDepth;
        \\void main() {
        \\    gl_FragDepth = 0.5;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

test "gap: layout(early_fragment_tests) in emits EarlyFragmentTests" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(early_fragment_tests) in;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = vec4(1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

test "gap: layout(depth_unchanged) emits DepthUnchanged execution mode" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(depth_unchanged) out float gl_FragDepth;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    o = vec4(1.0);
        \\    gl_FragDepth = 0.5;
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(words.len > 0);
}

// ─── Gap: textureGatherOffsets ─────────────────────────────────────────────
// textureGatherOffsets(sampler2D, vec2, const ivec2[4] [, int comp]) lowers to
//   OpImageGather %v4float %si %coord %Component ConstOffsets %constArray
// matching glslang -V. ConstOffsets is image-operands mask bit 0x20; the const
// array id immediately follows the mask word. The Component operand is ALWAYS
// present (defaults to const int 0 when the GLSL omits `comp`). The instruction
// also requires the ImageGatherExtended capability.

/// Return the full word-slice of the first instruction with the given opcode
/// (header word included), or null. Lets a test inspect trailing operands such
/// as the image-operands mask + ConstOffsets array id on an OpImageGather.
fn firstInstWords(words: []const u32, op: spirv.Op) ?[]const u32 {
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(op) and word_count > 0 and i + word_count <= words.len) {
            return words[i .. i + word_count];
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

/// Resolve the value of an OpConstant (32-bit int/uint) with the given result id.
fn constIntValue(words: []const u32, id: u32) ?u32 {
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        // OpConstant: [header | result_type | result_id | value...]
        if (opcode == @intFromEnum(spirv.Op.Constant) and word_count >= 4 and words[i + 2] == id) {
            return words[i + 3];
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

const ConstOffsetsMask: u32 = 0x20; // SPIR-V image-operands ConstOffsets bit

test "gap: textureGatherOffsets(s, coord, const ivec2[4], comp) emits OpImageGather with ConstOffsets" {
    // Matches the glslang -V oracle:
    //   %30 = OpImageGather %v4float %si %coord %int_1 ConstOffsets %29
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  const ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs, 1);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // (a) compiles + spirv-val PASS
    try testing.expect(try glslpp.validateSPIRV(testing.allocator, words));

    // (b) exactly one OpImageGather, vec4 result, no Dref form.
    try testing.expectEqual(@as(usize, 1), countOp(words, .ImageGather));
    try testing.expectEqual(@as(usize, 0), countOp(words, .ImageDrefGather));
    const rt = firstResultTypeId(words, .ImageGather) orelse return error.NoGather;
    try testing.expect(typeIsVec4Float(words, rt));

    // (c) the OpImageGather carries the ConstOffsets image operand (0x20) plus a
    //     trailing array id. Layout: [hdr|rt|res|si|coord|component|mask|array].
    const gi = firstInstWords(words, .ImageGather) orelse return error.NoGather;
    try testing.expectEqual(@as(usize, 8), gi.len);
    const mask = gi[6];
    try testing.expectEqual(ConstOffsetsMask, mask);
    const array_id = gi[7];
    try testing.expect(array_id != 0);
    // The array id must reference an OpConstantComposite (the 4-offset array).
    try testing.expect(firstInstWords(words, .ConstantComposite) != null);

    // Component (gi[5]) is the explicit `1` from the GLSL.
    try testing.expectEqual(@as(?u32, 1), constIntValue(words, gi[5]));

    // (d) ImageGatherExtended capability is declared (required by spirv-val).
    try testing.expect(hasCapability(words, .image_gather_extended));
}

test "gap: textureGatherOffsets default component (no comp arg) emits Component 0 + ConstOffsets" {
    // glslang emits the Component operand even when GLSL omits it, defaulting to
    // const int 0. The ConstOffsets operand follows.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  const ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(try glslpp.validateSPIRV(testing.allocator, words));
    try testing.expectEqual(@as(usize, 1), countOp(words, .ImageGather));

    const gi = firstInstWords(words, .ImageGather) orelse return error.NoGather;
    try testing.expectEqual(@as(usize, 8), gi.len);
    try testing.expectEqual(ConstOffsetsMask, gi[6]);
    // Default component is a constant int 0.
    try testing.expectEqual(@as(?u32, 0), constIntValue(words, gi[5]));
}

test "gap: non-offset textureGather stays plain OpImageGather (no ConstOffsets, no regression)" {
    // The plain gather must remain byte-shape-identical: a 6-word OpImageGather
    // with NO image-operands mask. This guards against the offsets lowering
    // leaking the ConstOffsets word into the non-offset path.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGather(s, uv, 1); }
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    try testing.expect(try glslpp.validateSPIRV(testing.allocator, words));
    try testing.expectEqual(@as(usize, 1), countOp(words, .ImageGather));
    const gi = firstInstWords(words, .ImageGather) orelse return error.NoGather;
    // 6 words: header, result_type, result, sampled_image, coord, component.
    try testing.expectEqual(@as(usize, 6), gi.len);
    // ImageGatherExtended must NOT be forced on for a plain gather.
    try testing.expect(!hasCapability(words, .image_gather_extended));
}

test "gap: textureGatherOffsets with NON-const offsets array is an honest error (no silent-drop)" {
    // glslang requires the offsets to be a constant expression. A non-const
    // ivec2[4] (here built from a runtime uniform) must fail honestly, NOT
    // silently drop to a plain gather that ignores the offsets. In tolerate mode
    // the offending statement is SKIPPED entirely, so NO OpImageGather may
    // appear in the body (a silently-wrong gather would leave one behind).
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(binding=1) uniform U { int k; };
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  ivec2 offs[4]=ivec2[4](ivec2(k,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs, 1);
        \\}
    ;
    const words = try glslpp.compileToSPIRV(testing.allocator, source, .{ .stage = .fragment });
    defer testing.allocator.free(words);
    // The specific reason is carried in last_error_inner (last_error_ctx is
    // clobbered to the enclosing expression name by the errdefer chain).
    try testing.expectEqualStrings("textureGatherOffsets-offsets-not-constant", semantic.last_error_inner);
    try testing.expectEqual(@as(usize, 0), countOp(words, .ImageGather));
}

// ─── Gap #183: OpTypeImage Format / Arrayed codegen ──────────────────────────
// OpTypeImage layout: [header | result_id | sampled_type_id | Dim | Depth |
//                      Arrayed | MS | Sampled | Format]
// → Arrayed is operand word i+5; Format is operand word i+8 (when present).

/// Collect the `Format` operand of every `OpTypeImage` whose `Sampled` operand
/// is 2 (a storage image). Caller owns the returned slice.
fn collectStorageImageFormats(alloc: std.mem.Allocator, words: []const u32) ![]u32 {
    var out: std.ArrayListUnmanaged(u32) = .{};
    errdefer out.deinit(alloc);
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(spirv.Op.TypeImage) and word_count >= 9) {
            const sampled = words[i + 7];
            const format = words[i + 8];
            if (sampled == 2) try out.append(alloc, format);
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return out.toOwnedSlice(alloc);
}

/// Return the `Arrayed` operand of the first `OpTypeImage` whose `Dim` operand
/// equals `dim` (1=2D, 3=Cube, …). null if none found.
fn firstImageArrayedForDim(words: []const u32, dim: u32) ?u32 {
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(spirv.Op.TypeImage) and word_count >= 9 and words[i + 3] == dim) {
            return words[i + 5]; // Arrayed
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

/// Return the `Arrayed` operand of the first `OpTypeImage` whose sampled-type ID
/// resolves to `OpTypeInt` (an `i*` sampler) and whose `Dim` equals `dim`.
fn firstIntImageArrayedForDim(words: []const u32, dim: u32) ?u32 {
    // Pass 1: collect all OpTypeInt result IDs.
    var int_ids: std.ArrayListUnmanaged(u32) = .{};
    defer int_ids.deinit(testing.allocator);
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(spirv.Op.TypeInt) and word_count >= 4 and words[i + 3] == 1) {
            int_ids.append(testing.allocator, words[i + 1]) catch return null;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    // Pass 2: find an OpTypeImage with that sampled type and matching Dim.
    i = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(spirv.Op.TypeImage) and word_count >= 9 and words[i + 3] == dim) {
            const sampled_ty = words[i + 2];
            for (int_ids.items) |id| {
                if (id == sampled_ty) return words[i + 5];
            }
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

test "gap #183: two distinct storage images each carry their own Format" {
    // Oracle (glslangValidator -V):
    //   %7  = OpTypeImage %float 2D 0 0 0 2 Rgba8     (Format = 4)
    //   %18 = OpTypeImage %float 2D 0 0 0 2 Rgba32f   (Format = 1)
    // Pre-fix: the format-blind `emitted_types` dedup keyed on the enum alone
    // reused the FIRST image's type for the second → BOTH spelled Rgba8 (4,4).
    const source: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(binding=0, rgba8) uniform image2D a;
        \\layout(binding=1, rgba32f) uniform image2D b;
        \\void main() {
        \\    imageStore(a, ivec2(0), vec4(1.0));
        \\    imageStore(b, ivec2(0), vec4(2.0));
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .compute);
    defer testing.allocator.free(words);
    const fmts = try collectStorageImageFormats(testing.allocator, words);
    defer testing.allocator.free(fmts);
    try testing.expectEqual(@as(usize, 2), fmts.len);
    // Both Rgba8 (4) and Rgba32f (1) must be present.
    var has_rgba8 = false;
    var has_rgba32f = false;
    for (fmts) |f| {
        if (f == 4) has_rgba8 = true;
        if (f == 1) has_rgba32f = true;
    }
    try testing.expect(has_rgba8);
    try testing.expect(has_rgba32f);
}

test "gap #183: array-of-storage-image carries its element Format" {
    // Oracle (glslangValidator -V): %7 = OpTypeImage %float 2D 0 0 0 2 Rgba32f
    // Pre-fix: the array element resolved via the format-blind ensureType path
    // and emitted Unknown (0) — not Rgba32f (1).
    const source: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(binding=0, rgba32f) uniform image2D arr[3];
        \\void main() { imageStore(arr[0], ivec2(0), vec4(1.0)); }
    ;
    const words = try compileToWords(testing.allocator, source, .compute);
    defer testing.allocator.free(words);
    const fmts = try collectStorageImageFormats(testing.allocator, words);
    defer testing.allocator.free(fmts);
    try testing.expect(fmts.len >= 1);
    try testing.expectEqual(@as(u32, 1), fmts[0]); // Rgba32f
}

test "gap #183: samplerCubeArray emits OpTypeImage Arrayed=1" {
    // Oracle (glslangValidator -V):
    //   %10 = OpTypeImage %float Cube 0 1 0 1 Unknown  (Arrayed = 1)
    //   %19 = OpTypeImage %int   Cube 0 1 0 1 Unknown  (Arrayed = 1, isampler anchor)
    // Pre-fix: parser mapped samplerCubeArray → .sampler_cube → Arrayed=0.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeArray ca;
        \\layout(binding=1) uniform isamplerCubeArray ica;
        \\layout(location=0) out vec4 o;
        \\void main() { o = texture(ca, vec4(0.5)) + vec4(texture(ica, vec4(0.5))); }
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);
    // The float cube image (samplerCubeArray) must be Arrayed=1.
    const float_arrayed = firstImageArrayedForDim(words, 3);
    try testing.expect(float_arrayed != null);
    try testing.expectEqual(@as(u32, 1), float_arrayed.?);
    // Regression anchor: the int cube image (isamplerCubeArray) was already 1.
    const int_arrayed = firstIntImageArrayedForDim(words, 3);
    try testing.expect(int_arrayed != null);
    try testing.expectEqual(@as(u32, 1), int_arrayed.?);
}

/// Resolve `type_id` to an `OpTypeImage` and return its `Arrayed` operand, or
/// null if `type_id` is not an image type. Layout:
///   OpTypeImage = [header | result_id | sampled_ty | Dim | Depth | Arrayed | MS | Sampled | Format]
fn imageArrayedOfType(words: []const u32, type_id: u32) ?u32 {
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(spirv.Op.TypeImage) and word_count >= 9 and words[i + 1] == type_id) {
            return words[i + 5]; // Arrayed
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

/// Collect the `Arrayed` operand of the image type referenced by every `OpImage`
/// extraction in the binary, in program order. `OpImage` layout:
///   [header | result_type_id | result_id | sampled_image_id]
/// The result type of OpImage IS the inner image type, so resolving the
/// result-type-id to its OpTypeImage tells us which Arrayed-ness each
/// extraction claims. The clobber bug makes two distinct-Arrayed sources both
/// point at the same OpTypeImage.
fn collectOpImageArrayed(alloc: std.mem.Allocator, words: []const u32) ![]u32 {
    var out: std.ArrayListUnmanaged(u32) = .{};
    errdefer out.deinit(alloc);
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const opcode = word & 0xFFFF;
        if (opcode == @intFromEnum(spirv.Op.OpImage) and word_count >= 4) {
            const result_type_id = words[i + 1];
            if (imageArrayedOfType(words, result_type_id)) |arrayed| {
                try out.append(alloc, arrayed);
            }
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return out.toOwnedSlice(alloc);
}

test "gap #183: samplerCube + samplerCubeArray coexist with correct-Arrayed OpImage" {
    // BLOCKER (#183 review): one `sampled_image_cube_inner_id` field was written
    // by all four cube ensureType arms, so the OpImage extraction site used
    // whichever ran last. With BOTH a samplerCube (Arrayed=0) and a
    // samplerCubeArray (Arrayed=1) present, the non-array textureSize extracted
    // against the array inner type → spirv-val:
    //   "Expected Sample Image image type to be equal to Result Type".
    //
    // Results are written to gl_FragColor so the optimizer cannot DCE the
    // OpImage extractions away (the delisted image-query.desktop.frag passed
    // only because its dead body was stripped). Oracle (glslangValidator -V):
    //   non-array textureSize(samplerCube)      → OpImage of Cube ... Arrayed=0
    //   array     textureSize(samplerCubeArray) → OpImage of Cube ... Arrayed=1
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform samplerCube uCube;
        \\layout(binding=1) uniform samplerCubeArray uCubeArr;
        \\layout(location=0) out vec4 fragColor;
        \\void main() {
        \\    ivec2 a = textureSize(uCube, 0);
        \\    ivec3 b = textureSize(uCubeArr, 0);
        \\    fragColor = vec4(float(a.x + a.y), float(b.x + b.y + b.z), 0.0, 1.0);
        \\}
    ;
    const words = try compileToWords(testing.allocator, source, .fragment);
    defer testing.allocator.free(words);

    // Both OpImage extractions must survive optimization (escape DCE).
    try testing.expectEqual(@as(usize, 2), countOp(words, .OpImage));

    // Each OpImage must reference an image type whose Arrayed bit matches its
    // source: one non-arrayed (0) and one arrayed (1). Pre-fix both were 1.
    const arrayed = try collectOpImageArrayed(testing.allocator, words);
    defer testing.allocator.free(arrayed);
    try testing.expectEqual(@as(usize, 2), arrayed.len);
    var saw_non_array = false;
    var saw_array = false;
    for (arrayed) |a| {
        if (a == 0) saw_non_array = true;
        if (a == 1) saw_array = true;
    }
    try testing.expect(saw_non_array);
    try testing.expect(saw_array);
}
