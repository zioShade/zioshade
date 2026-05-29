// SPDX-License-Identifier: MIT OR Apache-2.0
//! Semantic builtin-registration correctness tests.
//!
//! These tests guard against the analyzer SILENTLY over-rejecting valid GLSL
//! builtins. Tolerate mode (`compileToSPIRV`) swallows a statement whose
//! analysis throws (e.g. an unknown identifier/call), leaving `main()` an
//! empty body. Loose `assertContains("float4")`-style tests pass on that empty
//! output (false-green). The tests here assert REAL SPIR-V structure — BuiltIn
//! decorations and the lowered column-decomposition ops — so an empty/dropped
//! body fails loudly.
const std = @import("std");
const glslpp = @import("glslpp");
const diagnostic = glslpp.diagnostic;

const alloc = std.testing.allocator;

// SPIR-V opcodes / enums used below (from the SPIR-V spec):
//   OpStore = 62, OpDecorate = 71, OpCompositeConstruct = 80,
//   OpCompositeExtract = 81, OpFMul = 133.
//   OpCapability = 17, OpExtInst = 12, OpVariable = 59.
//   Decoration.BuiltIn = 11, BuiltIn.PointCoord = 16.
//   Capability.InterpolationFunction = 52, StorageClass.Input = 1.
//   GLSL.std.450: InterpolateAtCentroid = 76, InterpolateAtSample = 77,
//   InterpolateAtOffset = 78.
const OP_STORE: u32 = 62;
const OP_DECORATE: u32 = 71;
const OP_COMPOSITE_CONSTRUCT: u32 = 80;
const OP_COMPOSITE_EXTRACT: u32 = 81;
const OP_FMUL: u32 = 133;
const OP_CAPABILITY: u32 = 17;
const OP_EXT_INST: u32 = 12;
const OP_VARIABLE: u32 = 59;
const DECORATION_BUILTIN: u32 = 11;
const BUILTIN_POINT_COORD: u32 = 16;
const CAP_INTERPOLATION_FUNCTION: u32 = 52;
const STORAGE_CLASS_INPUT: u32 = 1;
const EXT_INTERPOLATE_AT_CENTROID: u32 = 76;
const EXT_INTERPOLATE_AT_SAMPLE: u32 = 77;
const EXT_INTERPOLATE_AT_OFFSET: u32 = 78;

/// Count how many instructions in the module have the given opcode.
fn countOpcode(spv: []const u32, opcode: u32) usize {
    var i: usize = 5; // skip 5-word header
    var n: usize = 0;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == opcode) n += 1;
        i += wc;
    }
    return n;
}

/// True if the module contains `OpDecorate <id> BuiltIn <builtin>`.
fn hasBuiltInDecoration(spv: []const u32, builtin: u32) bool {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        // OpDecorate <target> <decoration> <literal...>
        if (op == OP_DECORATE and wc >= 4 and i + 3 < spv.len and
            spv[i + 2] == DECORATION_BUILTIN and spv[i + 3] == builtin)
        {
            return true;
        }
        i += wc;
    }
    return false;
}

/// True if the module declares `OpCapability <cap>`.
fn hasCapability(spv: []const u32, cap: u32) bool {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OP_CAPABILITY and wc >= 2 and i + 1 < spv.len and spv[i + 1] == cap) {
            return true;
        }
        i += wc;
    }
    return false;
}

/// Return the `interpolant` operand id of the first
/// `OpExtInst <type> <id> <glsl450-set> <ext_op> <interpolant> ...` whose
/// extended-instruction number equals `ext_op`, or null if none.
///
/// OpExtInst layout: word0 = header, word1 = result type, word2 = result id,
/// word3 = ext-inst set id, word4 = ext-inst literal, word5 = first operand.
fn extInstFirstOperand(spv: []const u32, ext_op: u32) ?u32 {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OP_EXT_INST and wc >= 6 and i + 5 < spv.len and spv[i + 4] == ext_op) {
            return spv[i + 5];
        }
        i += wc;
    }
    return null;
}

/// True if `id` is declared by an `OpVariable <type> <id> <storage_class>`
/// with the given storage class. OpVariable layout: word0 = header,
/// word1 = result type, word2 = result id, word3 = storage class.
fn isVariableWithStorageClass(spv: []const u32, id: u32, sc: u32) bool {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OP_VARIABLE and wc >= 4 and i + 3 < spv.len and
            spv[i + 2] == id and spv[i + 3] == sc)
        {
            return true;
        }
        i += wc;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Phase 1: gl_PointCoord
// ---------------------------------------------------------------------------

test "gl_PointCoord: fragment shader emits BuiltIn PointCoord and non-empty body" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(gl_PointCoord, 0.0, 1.0); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    // The store to `o` must survive — tolerate mode would otherwise drop the
    // whole statement (empty body) when gl_PointCoord was unknown.
    try std.testing.expect(countOpcode(spv, OP_STORE) >= 1);

    // gl_PointCoord must be decorated as BuiltIn PointCoord (16).
    try std.testing.expect(hasBuiltInDecoration(spv, BUILTIN_POINT_COORD));
}

// ---------------------------------------------------------------------------
// Phase 2: matrixCompMult
// ---------------------------------------------------------------------------

test "matrixCompMult: lowers to per-column FMul + matrix CompositeConstruct" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    mat3 a = mat3(1.0); mat3 b = mat3(2.0);
        \\    mat3 c = matrixCompMult(a, b);
        \\    o = vec4(c[0], 1.0);
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    // Body must survive — tolerate mode would otherwise drop the statements
    // (empty body) when matrixCompMult was unknown.
    try std.testing.expect(countOpcode(spv, OP_STORE) >= 1);

    // Column decomposition: one OpFMul per column (3 for mat3) of vector
    // operands, then an OpCompositeConstruct that rebuilds the result matrix.
    try std.testing.expect(countOpcode(spv, OP_FMUL) >= 3);
    try std.testing.expect(countOpcode(spv, OP_COMPOSITE_EXTRACT) >= 3);
    try std.testing.expect(countOpcode(spv, OP_COMPOSITE_CONSTRUCT) >= 1);
}

// ---------------------------------------------------------------------------
// Regression oracle (Bug #3.B false-positive): a shader using ONLY these two
// now-modeled builtins must compile with ZERO diagnostics. Before the fix the
// analyzer threw on each, tolerate mode recorded the errors, and
// compileToSPIRVWithDiagnostics fail-loud'd. Now it must succeed cleanly.
// ---------------------------------------------------------------------------

test "matrixCompMult + gl_PointCoord: compileToSPIRVWithDiagnostics succeeds with zero diagnostics" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    mat3 c = matrixCompMult(mat3(1.0), mat3(2.0));
        \\    o = vec4(c[0] * gl_PointCoord.x, 1.0);
        \\}
    ;
    var diags: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    const words = try glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags);
    defer alloc.free(words);

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    // And the body actually survives (non-empty).
    try std.testing.expect(countOpcode(words, OP_STORE) >= 1);
}

// ---------------------------------------------------------------------------
// Phase 3: interpolateAtCentroid / interpolateAtSample / interpolateAtOffset
//
// These GLSL.std.450 ext-insts (76/77/78) are NOT plain ext_inst lowerings:
//   1. The `interpolant` operand MUST be a POINTER to an Input variable — NOT
//      a loaded r-value. spirv-val rejects a loaded value here.
//   2. The module MUST declare OpCapability InterpolationFunction (52).
// Each test asserts the OpExtInst exists with the right number, that its first
// operand is an OpVariable with Input storage class, and that the capability is
// present. A dropped (tolerate-mode) body has no OpExtInst → fails loudly.
// ---------------------------------------------------------------------------

test "interpolateAtCentroid: OpExtInst 76 with Input-pointer interpolant + InterpolationFunction cap" {
    const source =
        \\#version 450
        \\layout(location=0) in vec4 v_color;
        \\layout(location=0) out vec4 o;
        \\void main() { o = interpolateAtCentroid(v_color); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    const interpolant = extInstFirstOperand(spv, EXT_INTERPOLATE_AT_CENTROID) orelse
        return error.MissingInterpolateAtCentroid;
    try std.testing.expect(isVariableWithStorageClass(spv, interpolant, STORAGE_CLASS_INPUT));
    try std.testing.expect(hasCapability(spv, CAP_INTERPOLATION_FUNCTION));
    try std.testing.expect(countOpcode(spv, OP_STORE) >= 1);
}

test "interpolateAtSample: OpExtInst 77 with Input-pointer interpolant + InterpolationFunction cap" {
    const source =
        \\#version 450
        \\layout(location=0) in vec4 v_color;
        \\layout(location=0) out vec4 o;
        \\void main() { o = interpolateAtSample(v_color, 0); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    const interpolant = extInstFirstOperand(spv, EXT_INTERPOLATE_AT_SAMPLE) orelse
        return error.MissingInterpolateAtSample;
    try std.testing.expect(isVariableWithStorageClass(spv, interpolant, STORAGE_CLASS_INPUT));
    try std.testing.expect(hasCapability(spv, CAP_INTERPOLATION_FUNCTION));
    try std.testing.expect(countOpcode(spv, OP_STORE) >= 1);
}

test "interpolateAtOffset: OpExtInst 78 with Input-pointer interpolant + InterpolationFunction cap" {
    const source =
        \\#version 450
        \\layout(location=0) in vec4 v_color;
        \\layout(location=0) out vec4 o;
        \\void main() { o = interpolateAtOffset(v_color, vec2(0.25, 0.25)); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    const interpolant = extInstFirstOperand(spv, EXT_INTERPOLATE_AT_OFFSET) orelse
        return error.MissingInterpolateAtOffset;
    try std.testing.expect(isVariableWithStorageClass(spv, interpolant, STORAGE_CLASS_INPUT));
    try std.testing.expect(hasCapability(spv, CAP_INTERPOLATION_FUNCTION));
    try std.testing.expect(countOpcode(spv, OP_STORE) >= 1);
}

test "interpolateAt*: compileToSPIRVWithDiagnostics succeeds with zero diagnostics" {
    const source =
        \\#version 450
        \\layout(location=0) in vec2 v_uv;
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    vec2 c = interpolateAtCentroid(v_uv);
        \\    vec2 s = interpolateAtSample(v_uv, 1);
        \\    vec2 f = interpolateAtOffset(v_uv, vec2(0.1, 0.1));
        \\    o = vec4(c + s + f, 0.0, 1.0);
        \\}
    ;
    var diags: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    const words = try glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags);
    defer alloc.free(words);

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expect(countOpcode(words, OP_STORE) >= 1);
}
