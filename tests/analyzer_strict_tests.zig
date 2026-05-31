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
