const std = @import("std");
const glslpp = @import("glslpp");

// ============================================================
// CLASSIFICATION TABLE — enumerate-fp run 2026-05-31
// Total FP candidates: 28
//
// | construct            | representative ctx         | count | glslang verdict | bucket        |
// |----------------------|----------------------------|-------|-----------------|---------------|
// | compound_assign (gl) | newTexture.frag            |   2   | REJECT (binding)| true-reject   |
// | assign_op (gl)       | spv.AofA.frag              |   1   | REJECT (loc)    | true-reject   |
// | assign_op (gl)       | spv.double.comp            |   1   | REJECT (binding)| true-reject   |
// | assign_op (sc)       | crop_circle.frag           |   1   | REJECT (loc)    | true-reject   |
// | assign_op (sc)       | struct-material.frag       |   1   | REJECT (syntax) | true-reject   |
// | type-mismatch (sc)   | ray_sphere_test.frag       |   1   | REJECT (loc)    | true-reject   |
// | type-mismatch (sc)   | weathervane.frag           |   1   | REJECT (conv)   | true-reject   |
// | binary_op (sc)       | nested-funcalls.frag       |   1   | REJECT (syntax) | true-reject   |
// | type_constructor     | global-var-funcs.frag      |   1   | REJECT (syntax) | true-reject   |
// | hash                 | aztec-pattern.frag         |   1   | REJECT (undef)  | true-reject   |
// | step                 | chemical-atom.frag         |   1   | REJECT (undef a)| true-reject   |
// | not                  | vec_compare.frag           |   1   | REJECT (es+vk)  | true-reject   |
// | binary_op (stress)   | wgsl_global_const.frag     |   1   | REJECT (undef)  | true-reject   |
// | saturate             | wgsl_saturate.frag         |   1   | REJECT (uniform)| true-reject   |
// | assign_op (gl)       | spv.nvAtomicFp16Vec.frag   |   1   | ACCEPT          | F1 (f16 types)|
// | compound_assign (sc) | fp64.desktop.comp          |   1   | ACCEPT          | F1 (double)   |
// | compound_assign (sc) | int64.desktop.comp         |   1   | ACCEPT          | F1 (int64)    |
// | compound_assign (sc) | barycentric-khr-io-block   |   1   | ACCEPT          | F1 (pervertexEXT) |
// | cubeFaceIndexAMD     | gcn_shader.comp            |   1   | ACCEPT          | F1 (AMD+int64)|
// | clockRealtime2x32EXT | shader-clock.frag          |   1   | ACCEPT          | F1 (EXT+int64)|
// | mbcntAMD             | shader_ballot.comp         |   1   | ACCEPT          | F1 (AMD ballot)|
// | assign_op            | composite-construct.comp   |   1   | ACCEPT          | Task 1 (FP)   |
// | assign_op            | extended-arithmetic.comp   |   1   | ACCEPT          | Task 1 (FP)   |
// | assign_op            | shared.comp                |   1   | ACCEPT          | Task 1 (FP)   |
// | assign_op            | spec-const-wgsize.vk.comp  |   1   | ACCEPT          | Task 1 (FP)   |
// | assign_op            | ssbo-array.comp            |   1   | ACCEPT          | Task 1 (FP)   |
// | type-mismatch        | image-query.desktop.frag   |   1   | ACCEPT          | Task 1 (FP)   |
//
// Summary:
//   True rejections (glslang also rejects):      15  -- leave as-is
//   F1 honest-error (glslang accepts, unrepresentable): 7  -- Task F1
//   Task 1 false-positives (glslang accepts, fixable):  6  -- Task 1
//
// Legend: (gl)=glslang-430 suite, (sc)=spirv-cross suite, (stress)=conformance/stress
// ============================================================

test "harness self-test: compileToSPIRVStrict rejects a recorded error" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(undeclared_xyz, 0.0, 0.0, 1.0); }
    ;
    // The strict arm is the enumerator's detection signal; it must fire.
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment }));
}
