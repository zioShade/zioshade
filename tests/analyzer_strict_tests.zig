const std = @import("std");
const glslpp = @import("glslpp");

// ============================================================
// CLASSIFICATION TABLE — enumerate-fp run 2026-05-31 (CORRECTED)
//
// Methodology — TWO signals (bare `glslangValidator -V` is NOT enough: it
// rejects valid constructs for Vulkan LAYOUT reasons "missing location/binding"
// that are orthogonal to the construct under test):
//   (1) glslang construct verdict: `glslangValidator -V --aml --amb <fixture>`
//       (--auto-map-locations/--auto-map-bindings strip the layout noise).
//   (2) current conformance status (tolerate-compile + spirv-val): PASS means
//       glslpp emits STRUCTURALLY-valid SPIR-V — but verify FAITHFULNESS too
//       (e.g. `double` must emit OpTypeFloat 64; a builtin must emit its real
//       instruction, not a silent substitute / OpUndef).
//
// 4 buckets (see memory project_analyzer-fail-loud-task0-classification + task list):
//
// BUCKET 1 — GENUINE FALSE-POSITIVES (glslang ACCEPT + conf PASS + faithful)
//   → MODEL in Task 1; stays PASS. Many share ctx=assign_op/inner=func_call
//     → likely a few ROOT CAUSES, not N independent bugs.
//     spv.AofA.frag (arrays-of-arrays), composite-construct.comp, shared.comp,
//     ssbo-array.comp, spec-constant-work-group-size.vk.comp,
//     image-query.desktop.frag, vec_compare.frag (not() builtin; glslang
//     rejects only on ES-version-for-Vulkan policy — construct is valid).
//     PENDING faithfulness check (→ Bucket 2 if silent-wrong):
//     extended-arithmetic.desktop.comp, barycentric-khr-io-block.frag.
//
// BUCKET 2 — VALID but UNREPRESENTABLE, silently MISCOMPILED
//   (glslang ACCEPT + conf PASS but semantically-WRONG output)
//   → HONEST-ERROR (Task F1) + XFAIL (Task F3); leaves PASS.
//     spv.double.comp (emits NO OpTypeFloat 64 — silent f64→? downgrade),
//     gcn_shader.comp (AMD cubeFaceIndex/CoordAMD dropped — no OpExtInst),
//     shader-clock.frag (ARB/EXT clock), spv.nvAtomicFp16Vec.frag (NV fp16 atomics).
//
// BUCKET 3 — INVALID GLSL, silently MISCOMPILED (glslang REJECT real construct
//   error + conf PASS) → strict-reject is CORRECT. These are glslpp-AUTHORED
//   buggy fixtures (NOT canonical spirv-cross). USER DECISION: FIX to valid GLSL.
//     global-var-funcs.frag + nested-funcalls.frag (functions nested in main()),
//     crop_circle.frag (`flat` reserved keyword used as a var name),
//     aztec-pattern.frag + chemical-atom.frag (undeclared identifiers),
//     wgsl_global_const.frag (undeclared u_val),
//     wgsl_saturate.frag (`saturate` is HLSL/WGSL, not GLSL),
//     weathervane.frag (`float rose_center = vec2(...)` — vec2→float init).
//
// BUCKET 4 — CURRENT CONFORMANCE FAILS (conf FAIL spirv-val) = the original 7.
//     fp64.desktop.comp (double), int64.desktop.comp (int64)  → F1/XFAIL.
//     shader_ballot.comp (AMD ballot), struct-material.frag (glslang REJECTs
//       syntax mat2) → XFAIL.
//     newTexture.frag, spv.newTexture.frag, ray_sphere_test.frag → glslang
//       ACCEPTs; ASSESS whether CODEGEN-fixable to PASS (OpImageFetch/word-count)
//       vs unrepresentable before defaulting to XFAIL.
//
// NOTE: re-run `just enumerate-fp` after each Task-1 fix; cascade phantoms
// vanish when a root cause is modeled (the count is the true blast-radius).
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

test "strict: SSBO block array (buffer {...} name[N]) is accepted" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 310 es
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer SSBO { vec4 data[]; } ssbos[2];
        \\void main() {
        \\    uint ident = gl_GlobalInvocationID.x;
        \\    ssbos[1].data[ident] = ssbos[0].data[ident];
        \\}
    ;
    // tolerate-mode must compile without error
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .compute });
    defer alloc.free(spirv);
    try std.testing.expect(spirv.len > 5);

    // strict mode must also accept this valid construct (RED: currently rejects with UndeclaredIdentifier).
    // compileToSPIRVStrict is enumeration-only (returns empty slice on success), so we just check
    // it does NOT return an error.
    const spirv_strict = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .compute });
    // strict returns &[_]u32{} on success (enumeration-only path — no codegen); just verify no error.
    _ = spirv_strict;
}
