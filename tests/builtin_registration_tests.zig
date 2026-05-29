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

const alloc = std.testing.allocator;

// SPIR-V opcodes / enums used below (from the SPIR-V spec):
//   OpStore = 62, OpDecorate = 71, OpCompositeConstruct = 80,
//   OpCompositeExtract = 81, OpFMul = 133.
//   Decoration.BuiltIn = 11, BuiltIn.PointCoord = 16.
const OP_STORE: u32 = 62;
const OP_DECORATE: u32 = 71;
const OP_COMPOSITE_CONSTRUCT: u32 = 80;
const OP_COMPOSITE_EXTRACT: u32 = 81;
const OP_FMUL: u32 = 133;
const DECORATION_BUILTIN: u32 = 11;
const BUILTIN_POINT_COORD: u32 = 16;

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
