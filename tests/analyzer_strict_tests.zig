//! Strict-analyzer tests for the "analyzer fail-loud" milestone.
//!
//! These tests back the milestone that makes the plain `compileToSPIRV` /
//! `compileToSPIRVNoOpt` APIs fail loud on genuinely-broken shaders, after
//! eliminating every analyzer false-positive that forces tolerate mode today.
//!
//! Two kinds of test live here:
//!   1. Harness self-test — proves the strict-enumeration detection arm fires.
//!   2. Per-construct RED→GREEN assertions (added one bucket at a time in Task 1)
//!      and honest-error assertions (Task F1), plus the post-flip contract (Task F2).
//!
//! ── Classification table (Task 0 first run, 2026-05-31) ─────────────────────
//! Source: `just enumerate-fp` (28 candidates, 12 ctx buckets) cross-checked
//! against `glslangValidator -V --aml --amb` (auto-map locations/bindings so the
//! verdict reflects the construct, not glslpp-vs-glslang layout-strictness).
//!
//! RESOLVED so far:
//!   not(bvec)  → modeled (OpLogicalNot); fixture tests/conformance/stress/vec_not.frag
//!   tests/conformance/stress/vec_compare.frag    → fixture repaired (was ES-legacy gl_FragColor)
//!   tests/conformance/stress/wgsl_global_const.frag → fixture repaired (u_val was undeclared)
//!   tests/conformance/stress/wgsl_saturate.frag  → fixture repaired (saturate() is HLSL, now clamp)
//!   imageSize/textureSize dims → fixed (imageSize was always ivec2;
//!     textureSize(sampler2DMSArray) defaulted to ivec2). Fixture image_query_dims.frag.
//!   (enumerate-fp: 28 → 25 candidates)
//!
//! KNOWN REMAINING BLOCKER (separate, larger fix):
//!   tests/spirv-cross/image-query.desktop.frag still a candidate because the parser
//!   collapses float samplerCubeArray → .sampler_cube (parser.zig:702), dropping the
//!   array rank (silent-wrong: wrong SPIR-V image type + ivec2 textureSize). Needs a
//!   distinct .sampler_cube_array type threaded through codegen — tracked for follow-up.
//!
//! GROUP A — glslang ACCEPTS, glslpp can represent → FALSE-POSITIVE (Task 1, model):
//!   fixture                                       | ctx             | notes
//!   tests/glslang-430/spv.AofA.frag               | assign_op       | arrays-of-arrays
//!   tests/spirv-cross/composite-construct.comp    | assign_op       | composite ctor in assign
//!   tests/spirv-cross/shared.comp                 | assign_op       | shared-mem store
//!   tests/spirv-cross/ssbo-array.comp             | assign_op       | ssbo member store
//!   tests/spirv-cross/spec-constant-work-group-size.vk.comp | assign_op | spec-const wg size
//!   tests/spirv-cross/barycentric-khr-io-block.frag | compound_assign | io-block member
//!   tests/spirv-cross/image-query.desktop.frag    | type-mismatch   | imageSize/textureQuery
//!
//! GROUP B — glslang ACCEPTS, glslpp CANNOT represent → HONEST ERROR (Task F1):
//!   tests/spirv-cross/fp64.desktop.comp           | compound_assign | fp64/double (known-7)
//!   tests/glslang-430/spv.double.comp             | assign_op       | fp64/double
//!   tests/spirv-cross/int64.desktop.comp          | compound_assign | int64 (known-7)
//!   tests/glslang-430/spv.nvAtomicFp16Vec.frag    | assign_op       | fp16 + NV atomics
//!   tests/spirv-cross/gcn_shader.comp             | cubeFaceIndexAMD| AMD gcn builtin
//!   tests/spirv-cross/shader_ballot.comp          | mbcntAMD        | AMD ballot (known-7)
//!   tests/spirv-cross/shader-clock.frag           | clockRealtime2x32EXT | EXT shader clock
//!   tests/spirv-cross/extended-arithmetic.desktop.comp | assign_op  | uaddCarry/umulExtended (verify repr)
//!   tests/spirv-cross/ray_sphere_test.frag        | type-mismatch   | known-7; verify repr in Task 1
//!
//! GROUP C — glslang REJECTS (even --aml --amb) → glslpp strict is CORRECT.
//!   These are NOT false-positives. Each needs Task-1 triage: invalid fixture
//!   (fix/remove) vs glslang dialect-strictness. Post-F2 they become honest
//!   compile errors, so any in the conformance PASS set must be fixed or XFAIL'd.
//!   tests/spirv-cross/aztec-pattern.frag          | hash            | 'hash' no matching overload
//!   tests/spirv-cross/chemical-atom.frag          | step            | undeclared identifier 'a'
//!   tests/spirv-cross/crop_circle.frag            | assign_op       | syntax error (FLAT)
//!   tests/spirv-cross/global-var-funcs.frag       | type_constructor| syntax error
//!   tests/spirv-cross/nested-funcalls.frag        | binary_op       | syntax error
//!   tests/spirv-cross/struct-material.frag        | assign_op       | syntax error (MAT2) (known-7)
//!   tests/spirv-cross/weathervane.frag            | type-mismatch   | cannot convert type
//!   tests/conformance/stress/vec_compare.frag     | not             | invalid #version (ES<310) — fixture bug
//!   tests/conformance/stress/wgsl_global_const.frag | binary_op     | undeclared 'u_val'
//!   tests/conformance/stress/wgsl_saturate.frag   | saturate        | saturate() is HLSL, not GLSL
//! ────────────────────────────────────────────────────────────────────────────

const std = @import("std");
const glslpp = @import("glslpp");

test "harness self-test: compileToSPIRVStrict rejects a recorded error" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(undeclared_xyz, 0.0, 0.0, 1.0); }
    ;
    // The strict arm is the enumerator's detection signal; it must fire on a
    // permanent (flip-independent) error — an undeclared identifier, which
    // glslang rejects too, so this test is stable across Task 1 / F2.
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment }));
}

// ── Task 1 instances: modeled false-positives ───────────────────────────────

test "strict: not(bvec) relational builtin is accepted (no false-positive)" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    bvec2 lt = lessThan(gl_FragCoord.xy, vec2(0.5, 0.5));
        \\    bvec2 n = not(lt);
        \\    fragColor = vec4(float(n.x), float(n.y), 0.0, 1.0);
        \\}
    ;
    // Strict analysis must NOT reject valid GLSL using not() — glslang -V accepts it.
    const probe = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment });
    defer alloc.free(probe);

    // And codegen must lower it to a real OpLogicalNot (opcode 168), never OpUndef.
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expect(containsOpcode(spirv, 168)); // OpLogicalNot
    try std.testing.expect(!containsOpcode(spirv, 1)); // OpUndef must NOT appear

    // The fail-loud diagnostics path (used by the CLI) must also accept not().
    var diags: std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic) = .empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    const spirv2 = try glslpp.compileToSPIRVWithDiagnostics(alloc, src, .{ .stage = .fragment }, &diags);
    defer alloc.free(spirv2);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "strict: not() on a non-boolean operand fails loud (no silent-wrong)" {
    const alloc = std.testing.allocator;
    // not(float) and not(bool-scalar) are both rejected by glslang -V; glslpp must
    // not silently emit an invalid OpLogicalNot on a numeric/scalar type.
    const bad_float =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(float(not(3.0))); }
    ;
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRVStrict(alloc, bad_float, .{ .stage = .fragment }));
    const bad_scalar =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() { bool b = true; o = vec4(float(not(b))); }
    ;
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRVStrict(alloc, bad_scalar, .{ .stage = .fragment }));
}

test "strict: imageSize/textureSize result dims match operand rank (no false-positive)" {
    const alloc = std.testing.allocator;
    // imageSize previously always returned ivec2 (TypeMismatch for 1D/buffer/array/3D);
    // textureSize(sampler2DMSArray) previously defaulted to ivec2. glslang -V accepts.
    const src =
        \\#version 450
        \\layout(r32f, binding = 0) uniform image1D i1;
        \\layout(r32f, binding = 1) uniform image2DArray i2a;
        \\layout(r32f, binding = 2) uniform image3D i3;
        \\layout(r32f, binding = 3) uniform imageBuffer ib;
        \\layout(r32f, binding = 4) uniform imageCubeArray ica;
        \\layout(binding = 5) uniform sampler2DMSArray smsa;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    int a = imageSize(i1);
        \\    ivec3 c = imageSize(i2a);
        \\    ivec3 d = imageSize(i3);
        \\    int e = imageSize(ib);
        \\    ivec3 f = imageSize(ica);
        \\    ivec3 g = textureSize(smsa);
        \\    o = vec4(float(a + e), float(c.x + d.x), float(f.x + g.x), 1.0);
        \\}
    ;
    const probe = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment });
    defer alloc.free(probe);
    // Codegen must emit OpImageQuerySize (104) / OpImageQuerySizeLod (103), not OpUndef.
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expect(!containsOpcode(spirv, 1)); // no OpUndef
}

/// Scan a SPIR-V module for an instruction with the given opcode (low 16 bits of
/// each instruction's first word). Walks the instruction stream from the 5-word
/// header so operand words are never mistaken for opcodes.
fn containsOpcode(spirv: []const u32, opcode: u16) bool {
    if (spirv.len < 5) return false;
    var i: usize = 5;
    while (i < spirv.len) {
        const word = spirv[i];
        const op: u16 = @truncate(word & 0xFFFF);
        const word_count: usize = @as(u16, @truncate(word >> 16));
        if (word_count == 0) return false; // malformed; avoid infinite loop
        if (op == opcode) return true;
        i += word_count;
    }
    return false;
}
