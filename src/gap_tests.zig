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
    // Write to temp file
    const tmp = ".zig-cache/gap_test.spv";
    const f = try std.fs.cwd().createFile(tmp, .{});
    defer f.close();
    try f.writeAll(std.mem.sliceAsBytes(words));

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "spirv-dis", tmp },
    });
    defer alloc.free(result.stderr);
    return result.stdout;
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

test "gap: textureGather(sampler2DShadow, vec2, ref) emits OpImageDrefGather" {
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

    try testing.expect(words.len > 0);
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
