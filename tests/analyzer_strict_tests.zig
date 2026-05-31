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

test "strict: user function with 1D array parameter is accepted" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 430
        \\layout(location=0) out vec4 o;
        \\float sum(float a[3]) { return a[0]+a[1]+a[2]; }
        \\void main() { float v[3]; v[0]=1.0; v[1]=2.0; v[2]=3.0; o = vec4(sum(v)); }
    ;
    const spirv = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment });
    _ = spirv;
}

test "strict: user function with 2D array parameter is accepted (composite-construct fixture)" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 310 es
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer SSBO0 { vec4 as[]; };
        \\vec4 summe(vec4 values[3][2]) {
        \\    return values[0][0] + values[2][1];
        \\}
        \\void main() {
        \\    vec4 a[2]; a[0] = vec4(1.0); a[1] = vec4(2.0);
        \\    vec4 b[2]; b[0] = vec4(3.0); b[1] = vec4(4.0);
        \\    vec4 c[2]; c[0] = vec4(5.0); c[1] = vec4(6.0);
        \\    as[0] = summe(vec4[][](a, b, c));
        \\}
    ;
    const spirv = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .compute });
    _ = spirv;
}

test "strict: user function with 2D array param + return (AofA fixture)" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 430
        \\in float g5[5][7];
        \\out float outfloat;
        \\float[4][7] foo(float a[5][7]) {
        \\    float r[7];
        \\    r[0] = a[0][0];
        \\    return float[4][7](r, r, r, r);
        \\}
        \\void main() {
        \\    float g4[4][7];
        \\    g4 = foo(g5);
        \\    outfloat = g4[0][0];
        \\}
    ;
    const spirv = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment });
    _ = spirv;
}

test "strict: user function with 4-term 2D array expression (full composite-construct fixture body)" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 310 es
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer SSBO0 { vec4 as[]; };
        \\layout(std430, binding = 1) buffer SSBO1 { vec4 bs[]; };
        \\vec4 summe(vec4 values[3][2]) {
        \\    return values[0][0] + values[2][1] + values[0][1] + values[1][0];
        \\}
        \\void main() {
        \\    vec4 values[2] = vec4[](as[0], bs[0]);
        \\    vec4 const_values[2] = vec4[](vec4(10.0), vec4(30.0));
        \\    vec4 copy_values[2];
        \\    copy_values = const_values;
        \\    vec4 copy_values2[2] = values;
        \\    as[0] = summe(vec4[][](values, copy_values, copy_values2));
        \\}
    ;
    const spirv = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .compute });
    _ = spirv;
}

test "strict: shared array sized by gl_WorkGroupSize.x is accepted" {
    // RED: currently fails with ctx=assign_op because the parser cannot handle
    // expression-based array sizes like [gl_WorkGroupSize.x], causing the whole
    // sShared declaration to be discarded by error-recovery. The fix folds
    // gl_WorkGroupSize.x/y/z to local_size_x/y/z at the semantic level.
    const alloc = std.testing.allocator;
    const src =
        \\#version 310 es
        \\layout(local_size_x = 4) in;
        \\shared float sShared[gl_WorkGroupSize.x];
        \\layout(std430, binding = 0) readonly buffer SSBO { float in_data[]; };
        \\layout(std430, binding = 1) writeonly buffer SSBO2 { float out_data[]; };
        \\void main() {
        \\    uint ident = gl_GlobalInvocationID.x;
        \\    sShared[gl_LocalInvocationIndex] = in_data[ident];
        \\    memoryBarrierShared();
        \\    barrier();
        \\    out_data[ident] = sShared[gl_WorkGroupSize.x - gl_LocalInvocationIndex - 1u];
        \\}
    ;
    const spirv = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .compute });
    _ = spirv;
}

test "strict: not(bvec) / any(bvec) / all(bvec) builtins are accepted (vec_compare fixture)" {
    // RED: currently fails with ctx=not inner=func_call because `not` is not registered
    // as a GLSL builtin. any/all are registered but not(bvec) → OpLogicalNot is missing.
    // Use uniform inputs so the optimizer cannot fold the expression away.
    const alloc = std.testing.allocator;
    const src =
        \\precision mediump float;
        \\uniform vec2 ua;
        \\uniform vec2 ub;
        \\void main() {
        \\    bvec2 lt = lessThan(ua, ub);
        \\    bvec2 nlt = not(lt);
        \\    bool r = any(nlt);
        \\    bool s = all(lt);
        \\    gl_FragColor = vec4(r ? 1.0 : 0.0, s ? 1.0 : 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment });
    _ = spirv;
}

// ============================================================
// F2 flip contract tests — the plain compileToSPIRV/NoOpt APIs must
// fail loud on recorded errors after the fail_on_recorded_errors flag flip.
// ============================================================

test "flip: plain compileToSPIRV fails loud on a genuinely-broken shader" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(undeclared_identifier_xyz, 0, 0, 1); }
    ;
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment }));
}

test "flip: plain compileToSPIRV still accepts a valid shader" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expect(spirv.len > 5);
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

// ============================================================
// ROOT CAUSE FIXES — Tests for the 8 false-positives surfaced by fail-loud flip.
// Each test is RED (currently fails) → will turn GREEN after the fix.
// ============================================================

test "strict: outerProduct(vec2, vec3) produces mat3x2 (non-square matrix)" {
    // glslang: outerProduct(vec2 c, vec3 r) → mat3x2 (3 columns, 2 rows).
    // T64.1 was using mat2x3 (wrong type) — correct type is mat3x2.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location = 0) in vec2 a;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 b = vec3(1.0, 2.0, 3.0);
        \\    mat3x2 m = outerProduct(a, b);
        \\    fragColor = vec4(m[0].x, m[0].y, m[1].x, 1.0);
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spv.len > 5);
}

test "strict: for-loop with empty update and precision qualifier init (mediump int)" {
    // Precision qualifiers (mediump/highp/lowp) before a type in a for-loop init
    // were not recognized by parseStatement as local var decl prefixes, causing
    // the for loop to fail to parse. The body was then analyzed outside loop context,
    // causing continue-outside-loop. Fix: handle precision qualifiers in parseStatement.
    const alloc = std.testing.allocator;
    const src =
        \\#version 310 es
        \\precision mediump float;
        \\precision highp int;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    for (mediump int _46 = 0; _46 < 4; ) {
        \\        mediump int _33 = _46 + 1;
        \\        FragColor += vec4(float(_33));
        \\        _46 = _33;
        \\        continue;
        \\    }
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spv.len > 5);
}

test "strict: gl_MaxTextureImageUnits and gl_MaxCombinedTextureImageUnits" {
    // gl_Max* constants must be registered as builtin integer constants.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float a = x / float(gl_MaxTextureImageUnits);
        \\    float b = x / float(gl_MaxCombinedTextureImageUnits);
        \\    fragColor = vec4(a, b, 0.0, 1.0);
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spv.len > 5);
}

test "strict: textureGatherOffsets with global const ivec2[4] offsets" {
    // Global const array declarations must have is_const=true so that
    // textureGatherOffsets can verify the offsets argument is compile-time constant.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\layout(binding = 0) uniform sampler2D tex;
        \\const ivec2 offsets[4] = ivec2[4](ivec2(0,0), ivec2(1,0), ivec2(0,1), ivec2(1,1));
        \\void main() {
        \\    vec4 g = textureGatherOffsets(tex, uv, offsets, 0);
        \\    fragColor = g;
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spv.len > 5);
}

test "strict: SSBO array member swizzle compound-assign (p[id].vel.xyz += ...)" {
    // Compound-assign to a multi-component swizzle of a struct member accessed through
    // an SSBO array element (p[id].vel.xyz += ...) was failing with InvalidAssignment
    // because the compound_assign handler only handled the swizzle case for bare identifiers.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\struct Particle { vec4 pos; vec4 vel; };
        \\layout(std430, binding = 0) buffer Particles { Particle p[]; };
        \\void main() {
        \\    uint id = gl_GlobalInvocationID.x;
        \\    vec3 acc = vec3(0.0);
        \\    p[id].vel.xyz += acc * 0.01;
        \\    p[id].pos.xyz += p[id].vel.xyz * 0.01;
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .compute });
    defer alloc.free(spv);
    try std.testing.expect(spv.len > 5);
}

test "strict: pixel_interlock_ordered extension and SPIRV_Cross macro pattern" {
    // The spirv_cross pixel-interlock shader uses #ifdef GL_ARB_fragment_shader_interlock
    // BEFORE the #extension directive, so the macro must be pre-defined by the preprocessor
    // for supported extensions.
    const alloc = std.testing.allocator;
    const src = @embedFile("spirv_cross_shaders/pixel-interlock-ordered.frag");
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spv.len > 5);
}
