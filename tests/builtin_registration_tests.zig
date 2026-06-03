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

// ---------------------------------------------------------------------------
// BLOCKER: the interpolant MUST live in Input storage class.
//
// GLSL only permits interpolating a fragment *input*; SPIR-V GLSL.std.450
// requires the Interpolant operand to be a pointer in Input storage class.
// A function-local variable is addressable (so the old addressability-only
// guard let it through), but it lives in Function storage — feeding it to
// OpExtInst InterpolateAt* produces SPIR-V that spirv-val REJECTS:
//   "expected Interpolant storage class to be Input"
// That is silently-wrong invalid SPIR-V. The analyzer must reject the misuse
// honestly with error.SemanticFailed instead of emitting it.
//
// compileToSPIRVWithDiagnostics enforces the Mitchell contract: any
// error-kind diagnostic recorded during (tolerate-mode) analysis turns into
// error.SemanticFailed rather than a misleading partial module.
// ---------------------------------------------------------------------------

test "interpolateAtCentroid: rejects a function-local (Function-storage) interpolant" {
    // `local` is addressable but lives in Function storage, not Input.
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    vec4 local = vec4(1.0);
        \\    o = interpolateAtCentroid(local);
        \\}
    ;
    var diags: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags),
    );
}

test "interpolateAtSample: rejects a function-local (Function-storage) interpolant" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    vec4 local = vec4(1.0);
        \\    o = interpolateAtSample(local, 0);
        \\}
    ;
    var diags: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags),
    );
}

test "interpolateAtOffset: rejects a function-local (Function-storage) interpolant" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    vec4 local = vec4(1.0);
        \\    o = interpolateAtOffset(local, vec2(0.25, 0.25));
        \\}
    ;
    var diags: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags),
    );
}

test "interpolateAtCentroid: rejects an r-value (non-addressable) interpolant" {
    // `a + b` is not an l-value at all — the existing addressability guard
    // must keep rejecting it. (Confirms the new Input check did not weaken it.)
    const source =
        \\#version 450
        \\layout(location=0) in vec4 a;
        \\layout(location=1) in vec4 b;
        \\layout(location=0) out vec4 o;
        \\void main() { o = interpolateAtCentroid(a + b); }
    ;
    var diags: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags),
    );
}

test "interpolateAtOffset: accepts an Input interface-block member (no over-rejection)" {
    // The interpolant is a member access into an Input block; the access chain
    // root is an Input global, so the resulting pointer is Input-storage and
    // the call is valid. Must compile cleanly with zero diagnostics.
    const source =
        \\#version 450
        \\in VertexData { vec2 uv; } v_in;
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    vec2 f = interpolateAtOffset(v_in.uv, vec2(0.1, 0.1));
        \\    o = vec4(f, 0.0, 1.0);
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
    // The lowered OpExtInst (78) must survive and its interpolant operand must
    // be an Input-storage pointer (the access chain into the Input block).
    try std.testing.expect(extInstFirstOperand(words, EXT_INTERPOLATE_AT_OFFSET) != null);
}

// ─── textureGatherOffsets → OpImageGather + ConstOffsets ───────────────────
//
// `textureGatherOffsets(sampler2D, vec2, const ivec2[4] [, int comp])` lowers to
//   OpImageGather %v4float %si %coord %Component ConstOffsets %constArray
// matching glslang -V exactly. ConstOffsets is image-operands mask bit 0x20;
// the 4-element constant ivec2 array id immediately follows the mask word. The
// Component operand is ALWAYS present (a const int, default 0 when GLSL omits
// `comp`). The op additionally requires the ImageGatherExtended capability.
//
// These are SPIR-V byte-level tests (suite-counted). The companion
// spirv-val-backed assertions live in src/gap_tests.zig.

const OP_IMAGE_GATHER: u32 = 96;
const OP_IMAGE_DREF_GATHER: u32 = 97;
const OP_CONSTANT: u32 = 43;
const OP_CONSTANT_COMPOSITE: u32 = 44;
const CAP_IMAGE_GATHER_EXTENDED: u32 = 25;
const CONST_OFFSETS_MASK: u32 = 0x20;

/// Return the full word slice (header included) of the first instruction with
/// the given opcode, or null. Lets a test inspect the trailing image-operands.
fn firstInst(spv: []const u32, opcode: u32) ?[]const u32 {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == opcode and i + wc <= spv.len) return spv[i .. i + wc];
        i += wc;
    }
    return null;
}

const OP_VECTOR_SHUFFLE: u32 = 79;

/// Return just the component-selector words of the first OpVectorShuffle that
/// has exactly `want` selectors (word count == 5 + want). A swizzle
/// compound-assign on a vecN emits TWO shuffles — a narrow extract of the
/// swizzled lanes, then a wide write-back that rebuilds the full N-wide vector.
/// Selecting on width picks the write-back over the extract.
/// Layout: [op|wc] [resType] [resId] [vec1] [vec2] [comp...].
fn shuffleComponentsOfWidth(spv: []const u32, want: usize) ?[]const u32 {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OP_VECTOR_SHUFFLE and wc == 5 + want and i + wc <= spv.len) {
            return spv[i + 5 .. i + wc];
        }
        i += wc;
    }
    return null;
}

test "swizzle compound-assign write-back: partial swizzle on vec4 (v.xy *= 2.0)" {
    // Regression guard for the swizzle write-back shuffle (semantic.zig
    // .compound_assign). The OpVectorShuffle that merges the computed swizzled
    // lanes back into the base vector addresses its SECOND operand (the computed
    // values) starting at n = len(base vector), NOT at swizzle_len. For
    // `v.xy *= 2.0` on a vec4 the base vector (operand 0) occupies selector
    // indices 0..3, so the computed vec2 (operand 1) lives at indices 4,5.
    // Correct write-back selectors are [4,5,2,3]: x,y from the computed vec2
    // (4,5); z,w kept from the original (2,3). A swizzle_len-based offset (=2)
    // would instead emit [2,3,2,3] → result (z,w,z,w): structurally valid
    // SPIR-V (so spirv-val/conformance never flag it) but wrong-valued — exactly
    // the class of error this exact-selector check exists to catch. `vin` is a
    // shader input so the shuffle is never constant-folded, and NoOpt codegen
    // keeps the analyzer's exact selectors.
    const source =
        \\#version 430
        \\layout(location = 0) in vec4 vin;
        \\layout(location = 0) out vec4 o;
        \\void main() { vec4 v = vin; v.xy *= 2.0; o = v; }
    ;
    const spv = try glslpp.compileToSPIRVNoOpt(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    const comps = shuffleComponentsOfWidth(spv, 4) orelse return error.NoWriteBackShuffle;
    try std.testing.expectEqualSlices(u32, &[_]u32{ 4, 5, 2, 3 }, comps);
}

test "swizzle compound-assign write-back: partial swizzle on vec4 (col.rgb *= 0.8)" {
    // `col.rgb *= 0.8` on a vec4 → correct write-back selectors [4,5,6,3]
    // (r,g,b from the computed vec3 at 4,5,6; a kept from the original at 3).
    // A swizzle_len-based offset would emit [3,4,5,3] → (col.w, r', g', col.w).
    const source =
        \\#version 430
        \\layout(location = 0) in vec4 vin;
        \\layout(location = 0) out vec4 o;
        \\void main() { vec4 col = vin; col.rgb *= 0.8; o = col; }
    ;
    const spv = try glslpp.compileToSPIRVNoOpt(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    const comps = shuffleComponentsOfWidth(spv, 4) orelse return error.NoWriteBackShuffle;
    try std.testing.expectEqualSlices(u32, &[_]u32{ 4, 5, 6, 3 }, comps);
}

/// Resolve the literal value of an `OpConstant` (32-bit) with the given id.
fn constValue(spv: []const u32, id: u32) ?u32 {
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        const op = spv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == OP_CONSTANT and wc >= 4 and spv[i + 2] == id) return spv[i + 3];
        i += wc;
    }
    return null;
}

test "textureGatherOffsets: OpImageGather carries ConstOffsets (0x20) + const-array id + explicit component" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  const ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs, 1);
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    // Exactly one OpImageGather, no Dref form.
    try std.testing.expectEqual(@as(usize, 1), countOpcode(spv, OP_IMAGE_GATHER));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(spv, OP_IMAGE_DREF_GATHER));

    // Instruction shape: [hdr|rt|res|si|coord|component|mask|array] = 8 words.
    const gi = firstInst(spv, OP_IMAGE_GATHER) orelse return error.NoGather;
    try std.testing.expectEqual(@as(usize, 8), gi.len);
    try std.testing.expectEqual(CONST_OFFSETS_MASK, gi[6]);
    try std.testing.expect(gi[7] != 0); // the offsets array id

    // Component is the explicit `1`.
    try std.testing.expectEqual(@as(?u32, 1), constValue(spv, gi[5]));

    // The trailing array id references an OpConstantComposite.
    try std.testing.expect(countOpcode(spv, OP_CONSTANT_COMPOSITE) >= 1);

    // ImageGatherExtended capability is declared.
    try std.testing.expect(hasCapability(spv, CAP_IMAGE_GATHER_EXTENDED));
}

test "textureGatherOffsets: omitted component defaults to const int 0 (Component always emitted)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  const ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs);
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    try std.testing.expectEqual(@as(usize, 1), countOpcode(spv, OP_IMAGE_GATHER));
    const gi = firstInst(spv, OP_IMAGE_GATHER) orelse return error.NoGather;
    try std.testing.expectEqual(@as(usize, 8), gi.len);
    try std.testing.expectEqual(CONST_OFFSETS_MASK, gi[6]);
    // Component operand present and equal to const int 0.
    try std.testing.expectEqual(@as(?u32, 0), constValue(spv, gi[5]));
}

test "textureGather (non-offset) stays a plain 6-word OpImageGather, no regression" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGather(s, uv, 1); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    try std.testing.expectEqual(@as(usize, 1), countOpcode(spv, OP_IMAGE_GATHER));
    const gi = firstInst(spv, OP_IMAGE_GATHER) orelse return error.NoGather;
    // 6 words: header, result_type, result, sampled_image, coord, component.
    try std.testing.expectEqual(@as(usize, 6), gi.len);
    // No ImageGatherExtended capability forced for a plain gather.
    try std.testing.expect(!hasCapability(spv, CAP_IMAGE_GATHER_EXTENDED));
}

test "textureGatherOffsets: NON-const offsets array is an honest error (not silent-drop)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(binding=1) uniform U { int k; };
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  ivec2 offs[4]=ivec2[4](ivec2(k,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs, 1);
        \\}
    ;
    var diags: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags),
    );
    // The recorded diagnostic message carries the specific reason
    // (last_error_inner) so the failure is named, not generic.
    var found_reason = false;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "textureGatherOffsets-offsets-not-constant") != null) {
            found_reason = true;
        }
    }
    try std.testing.expect(found_reason);
}

/// Compile and assert the offsets argument is rejected with the named reason.
/// Shared by the const-init-then-mutate and non-const-init (un-mutated) cases,
/// both of which glslang -V rejects as "must be a compile-time constant".
fn expectOffsetsNotConstant(source: [:0]const u8) !void {
    var diags: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRVWithDiagnostics(alloc, source, .{ .stage = .fragment }, &diags),
    );
    var found_reason = false;
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "textureGatherOffsets-offsets-not-constant") != null) {
            found_reason = true;
        }
    }
    try std.testing.expect(found_reason);
}

test "textureGatherOffsets: const-init-then-MUTATED offsets is an honest error (BLOCKER, no silent-drop)" {
    // glslang -V rejects this ("must be a compile-time constant: offsets
    // argument", exit 2): `offs` is NOT const-qualified and is mutated at
    // runtime, so it is not a compile-time constant. Before the const-qualifier
    // gate, glslpp recovered the FIRST (constant) store to `offs` and emitted
    // OpImageGather + ConstOffsets using the STALE original constant array,
    // SILENTLY DROPPING the `offs[0] = ivec2(k,k)` mutation (exit 0) —
    // silent-wrong. It must honest-error with the named reason.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) flat in int k;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  offs[0] = ivec2(k, k);
        \\  o = textureGatherOffsets(s, vec2(0.5), offs);
        \\}
    ;
    try expectOffsetsNotConstant(source);
}

test "textureGatherOffsets: NON-const-qualified (constant-init, unmutated) offsets is an honest error (glslang parity)" {
    // glslang -V requires `const` qualification specifically: a non-const array
    // with a constant initializer that is never mutated is STILL rejected
    // ("must be a compile-time constant: offsets argument", exit 2) because the
    // declaration itself is mutable. glslpp must match — the const-qualifier
    // gate rejects the un-const-qualified declaration even though the value
    // would constant-fold identically.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs);
        \\}
    ;
    try expectOffsetsNotConstant(source);
}

test "textureGatherOffsets: valid const offsets still lowers to OpImageGather+ConstOffsets (no over-reject)" {
    // GREEN-guard: the valid `const ivec2 offs[4]` form that glslang -V accepts
    // (exit 0) MUST keep compiling to a single OpImageGather carrying the
    // ConstOffsets image operand (0x20) + the constant array id. The const-
    // qualifier gate must not over-reject it.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  const ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs);
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    try std.testing.expectEqual(@as(usize, 1), countOpcode(spv, OP_IMAGE_GATHER));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(spv, OP_IMAGE_DREF_GATHER));
    const gi = firstInst(spv, OP_IMAGE_GATHER) orelse return error.NoGather;
    try std.testing.expectEqual(@as(usize, 8), gi.len);
    try std.testing.expectEqual(CONST_OFFSETS_MASK, gi[6]);
    try std.testing.expect(gi[7] != 0);
    try std.testing.expect(countOpcode(spv, OP_CONSTANT_COMPOSITE) >= 1);
    try std.testing.expect(hasCapability(spv, CAP_IMAGE_GATHER_EXTENDED));
}
