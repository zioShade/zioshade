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

// Shared fixture: a single-dimension local array sized by ONE spec constant.
const SPEC_SIZED_ARRAY_SRC =
    \\#version 450
    \\layout(local_size_x = 1) in;
    \\layout(constant_id = 0) const int N = 4;
    \\layout(set = 0, binding = 0) buffer B { int v[]; };
    \\void main() {
    \\    int a[N];
    \\    for (int k = 0; k < N; k++) { a[k] = k * 2; }
    \\    int s = 0;
    \\    for (int k = 0; k < N; k++) { s += a[k]; }
    \\    v[0] = s;
    \\}
;

test "strict: local array sized by a spec constant is accepted by the analyzer" {
    // RED before this fix: parseLocalVarDecl only recognized int-literal array
    // sizes, so `int a[N]` (N a spec constant) mis-parsed — the `[N]` desynced
    // the declaration and the variable was typed as a non-array scalar, so the
    // later element store failed with ctx=assign_op.
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRVStrict(alloc, SPEC_SIZED_ARRAY_SRC, .{ .stage = .compute });
    _ = spirv;
}

test "codegen: spec-const-sized local array emits OpTypeArray %specConstId (not a baked literal)" {
    // compileToSPIRVStrict skips codegen, so it cannot verify the array LENGTH
    // operand. Run the full pipeline and assert the OpTypeArray length references
    // the spec-constant's result id — NOT a folded literal (which would ignore
    // pipeline overrides = silent-wrong). This guards the silent-wrong/regression
    // adjacent cases (multi-dim drop, const-int runtime-array) found in review.
    const alloc = std.testing.allocator;
    const spirv = try glslpp.compileToSPIRV(alloc, SPEC_SIZED_ARRAY_SRC, .{ .stage = .compute });
    defer alloc.free(spirv);

    // Find the spec constant's result id via `OpDecorate <id> SpecId k` (op 71, decoration 1).
    var spec_const_id: ?u32 = null;
    var i: usize = 5;
    while (i < spirv.len) {
        const wc: usize = spirv[i] >> 16;
        const op: u32 = spirv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == 71 and wc >= 4 and spirv[i + 2] == 1) spec_const_id = spirv[i + 1];
        i += wc;
    }
    try std.testing.expect(spec_const_id != null);

    // Find OpTypeArray (op 28): [hdr] result elemType lengthId. Assert lengthId is the spec const id.
    var array_len_is_spec_const = false;
    i = 5;
    while (i < spirv.len) {
        const wc: usize = spirv[i] >> 16;
        const op: u32 = spirv[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == 28 and wc == 4 and spirv[i + 3] == spec_const_id.?) array_len_is_spec_const = true;
        i += wc;
    }
    try std.testing.expect(array_len_is_spec_const);
}

test "strict: multi-dim spec-const-sized local array is an honest error (not silent-wrong)" {
    // A nested `int a[N][2]` with N a spec constant is NOT modeled (codegen only
    // handles a kept size_name on the OUTER, single dimension). It must fail loud
    // rather than silently drop the array and constant-fold its uses.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(constant_id = 0) const int N = 4;
        \\layout(set = 0, binding = 0) buffer B { int v[]; };
        \\void main() {
        \\    int a[N][2];
        \\    a[0][0] = 5; a[1][1] = 7;
        \\    v[0] = a[0][0] + a[1][1];
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .compute }));
}

test "strict: const-int-sized local array is an honest error (not an invalid runtime array)" {
    // `const int M = 4; int a[M];` — glslpp does not fold a plain `const int` name
    // to its literal, so it cannot emit a valid sized array. Keeping the size_name
    // would make codegen emit a Function-storage OpTypeRuntimeArray, which is
    // invalid Vulkan SPIR-V (VUID-04680). Fail loud instead of emitting it.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\const int M = 4;
        \\layout(set = 0, binding = 0) buffer B { int v[]; };
        \\void main() {
        \\    int a[M];
        \\    a[0] = 3;
        \\    v[0] = a[0];
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .compute }));
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

test "flip: fail-loud rejection after a completed user function leaks nothing" {
    // Regression guard for the fail-loud path (tolerate_errors=true +
    // fail_on_recorded_errors=true, as the plain compileToSPIRV API uses).
    // `helper(float)` analyzes successfully and is appended to Analyzer.functions
    // with an owned param_ids slice + body; `main` then records an undeclared-
    // identifier error, so analyzeWithOptions rejects at the fail_on_recorded_errors
    // gate BEFORE transferring functions to a Module. Cleanup is therefore owned by
    // Analyzer.deinit, not Module.deinit — if it stopped freeing the completed
    // function's param_ids/body, testing.allocator would flag the leak right here.
    // The other fail-loud tests only error inside main() (self.functions stays
    // empty), so this is the sole guard for the completed-function cleanup path.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\float helper(float x) { return x * 2.0; }
        \\void main() { o = vec4(helper(1.0), undeclared_xyz, 0.0, 1.0); }
    ;
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment }));
    // Pin the rejection to the *semantic* gate (not lex/parse): a function must
    // have been analyzed and recorded an error for the completed-function cleanup
    // path to be reachable. This keeps the guard from passing for the wrong reason
    // if error ordering ever changes.
    try std.testing.expectEqual(@as(?glslpp.CompileDetail, .semantic_failed), glslpp.last_compile_detail);
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

test "strict: partial swizzle compound-assign writes the correct components (regression: swizzle_len+j)" {
    // `col.rgb *= x` on a vec4 merges the computed rgb back via an OpVectorShuffle of
    // (original vec4, computed vec3). The swizzled lanes (0,1,2) MUST select from the
    // SECOND operand (indices >= n == 4); the non-swizzled lane (3) selects from the
    // first. A prior bug used `swizzle_len+j` (== 3+j) instead of `n+j` (== 4+j), so
    // lane r selected index 3 — silently writing col.w into col.r. Value-check the shuffle.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) in vec4 inCol;
        \\layout(location=0) out vec4 o;
        \\void main() { vec4 col = inCol; col.rgb *= 2.0; o = col; }
        ;
    const spv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    var i: usize = 5;
    var verified_merge = false;
    while (i < spv.len) {
        const wc: usize = spv[i] >> 16;
        const op: u16 = @truncate(spv[i] & 0xFFFF);
        if (wc == 0) break;
        // OpVectorShuffle (79) with 4 result components: [op|9] rtype rid v1 v2 c0 c1 c2 c3
        if (op == 79 and wc == 9) {
            const c0 = spv[i + 5];
            const c1 = spv[i + 6];
            const c2 = spv[i + 7];
            const c3 = spv[i + 8];
            // Identify the merge shuffle: at least one lane from the second operand
            // (>= 4) and at least one from the first (< 4). Ignore identity self-shuffles.
            if ((c0 >= 4 or c1 >= 4 or c2 >= 4) and (c0 < 4 or c1 < 4 or c2 < 4 or c3 < 4)) {
                // The three swizzled lanes (rgb) must come from the computed operand.
                try std.testing.expect(c0 >= 4);
                try std.testing.expect(c1 >= 4);
                try std.testing.expect(c2 >= 4);
                // The untouched lane (w) must come from the original.
                try std.testing.expect(c3 < 4);
                verified_merge = true;
            }
        }
        i += wc;
    }
    try std.testing.expect(verified_merge); // the merge shuffle must exist and be correct
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

// ============================================================
// F1 — Named honest-error for unsupported 64-bit types
// (Task F1 bounded: error-message quality, NOT type implementation)
// ============================================================

test "F1: double type yields a named honest unsupported error (not UndeclaredIdentifier)" {
    // The parser must recognise `double` as a 64-bit type keyword so the declaration
    // is parsed as a proper var_decl, and the semantic layer emits a clear error
    // naming the unsupported 64-bit type rather than a misleading UndeclaredIdentifier.
    // Note: use a plain float initialiser (no `lf` suffix) so the lexer does not
    // produce a stray `lf` identifier that would cause a parse error before the
    // semantic layer is even reached.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() { double d = 0.0; o = vec4(float(d)); }
    ;
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment }));
    const ctx = glslpp.lastErrorCtx() orelse "";
    const inner = glslpp.lastErrorInner() orelse "";
    // The error must NAME the unsupported 64-bit construct — NOT "UndeclaredIdentifier".
    // ctx or inner must contain "64" or "double".
    const names_it = std.mem.indexOf(u8, ctx, "64") != null or std.mem.indexOf(u8, ctx, "double") != null
        or std.mem.indexOf(u8, inner, "double") != null or std.mem.indexOf(u8, inner, "64") != null;
    try std.testing.expect(names_it);
}

test "F1: int64_t yields a named honest unsupported error" {
    // int64_t is parsed as a 64-bit type keyword so the declaration becomes a
    // proper var_decl, and the semantic layer emits a clear named error.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_ARB_gpu_shader_int64 : enable
        \\layout(location=0) out vec4 o;
        \\void main() { int64_t n = 5; o = vec4(float(n)); }
    ;
    try std.testing.expectError(error.SemanticFailed, glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment }));
    const ctx = glslpp.lastErrorCtx() orelse "";
    const inner = glslpp.lastErrorInner() orelse "";
    try std.testing.expect(std.mem.indexOf(u8, ctx, "64") != null or std.mem.indexOf(u8, inner, "int64") != null or std.mem.indexOf(u8, inner, "64") != null);
}

// Re-applied from main #45 / #42 follow-up during reconciliation.

test "strict: imageSize/textureSize result dims match operand rank (no false-positive)" {
    const alloc = std.testing.allocator;
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
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expect(!containsOpcode(spirv, 1));
}

test "strict: not() on a non-boolean operand fails loud (no silent-wrong)" {
    const alloc = std.testing.allocator;
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

// ============================================================
// GL_EXT/NV_fragment_shader_barycentric — HONEST faithfulness tests.
//
// These shaders previously compiled spirv-val-CLEAN but SILENTLY-WRONG:
// the `pervertexEXT`/`pervertexNV` interpolation qualifier was swallowed by
// the parser, the gl_BaryCoord* builtins got NO BuiltIn decoration, and the
// FragmentBarycentricKHR capability + SPV_*_fragment_shader_barycentric
// extension were never emitted. spirv-val tolerated the structurally-valid
// (but semantically-meaningless) result → a false-green.
//
// An honest test asserts the SEMANTICS, not just that spirv-val passes:
//   (1) compileToSPIRVStrict succeeds  → zero recorded diagnostics
//       (we model it; we do NOT fail-loud).
//   (2) the emitted SPIR-V actually carries the barycentric decorations &
//       capability that the glslangValidator -V --aml --amb oracle emits.
// Oracle ground-truth (spirv-dis):
//   OpCapability FragmentBarycentricKHR            (cap 5284)
//   OpExtension  "SPV_{KHR,NV}_fragment_shader_barycentric"
//   OpDecorate %gl_BaryCoordEXT       BuiltIn BaryCoordKHR        (5286)
//   OpDecorate %gl_BaryCoordNoPerspEXT BuiltIn BaryCoordNoPerspKHR (5287)
//   OpDecorate %vUV                   PerVertexKHR                (5285)
//   (io-block) OpDecorate %Foo Block + OpDecorate %foo PerVertexKHR
const CAP_FRAGMENT_BARYCENTRIC_KHR: u32 = 5284;
const BUILTIN_BARY_COORD_KHR: u32 = 5286;
const BUILTIN_BARY_COORD_NO_PERSP_KHR: u32 = 5287;
const DECO_PER_VERTEX_KHR: u32 = 5285;

test "strict: GL_EXT_fragment_shader_barycentric (pervertexEXT + gl_BaryCoordEXT) is modeled faithfully" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_fragment_shader_barycentric : require
        \\layout(location = 0) out vec2 value;
        \\layout(location = 0) pervertexEXT in vec2 vUV[3];
        \\layout(location = 3) pervertexEXT in vec2 vUV2[3];
        \\void main () {
        \\    value = gl_BaryCoordEXT.x * vUV[0] + gl_BaryCoordEXT.y * vUV[1] + gl_BaryCoordEXT.z * vUV[2];
        \\    value += gl_BaryCoordNoPerspEXT.x * vUV2[0] + gl_BaryCoordNoPerspEXT.y * vUV2[1] + gl_BaryCoordNoPerspEXT.z * vUV2[2];
        \\}
    ;
    // (1) modeled, not failed-loud
    _ = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment });
    // (2) faithful SPIR-V
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expect(hasCapability(spirv, CAP_FRAGMENT_BARYCENTRIC_KHR));
    try std.testing.expect(hasBuiltInDecoration(spirv, BUILTIN_BARY_COORD_KHR));
    try std.testing.expect(hasBuiltInDecoration(spirv, BUILTIN_BARY_COORD_NO_PERSP_KHR));
    try std.testing.expect(hasPlainDecoration(spirv, DECO_PER_VERTEX_KHR));
}

test "strict: GL_NV_fragment_shader_barycentric (pervertexNV + gl_BaryCoordNV) is modeled faithfully" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_NV_fragment_shader_barycentric : require
        \\layout(location = 0) out vec2 value;
        \\layout(location = 0) pervertexNV in vec2 vUV[3];
        \\layout(location = 1) pervertexNV in vec2 vUV2[3];
        \\void main () {
        \\    value = gl_BaryCoordNV.x * vUV[0] + gl_BaryCoordNV.y * vUV[1] + gl_BaryCoordNV.z * vUV[2];
        \\    value += gl_BaryCoordNoPerspNV.x * vUV2[0] + gl_BaryCoordNoPerspNV.y * vUV2[1] + gl_BaryCoordNoPerspNV.z * vUV2[2];
        \\}
    ;
    _ = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment });
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    // glslang canonicalizes the NV forms to the KHR capability/builtins;
    // only the OpExtension string differs (SPV_NV_…). So the same numeric
    // decorations must appear.
    try std.testing.expect(hasCapability(spirv, CAP_FRAGMENT_BARYCENTRIC_KHR));
    try std.testing.expect(hasBuiltInDecoration(spirv, BUILTIN_BARY_COORD_KHR));
    try std.testing.expect(hasBuiltInDecoration(spirv, BUILTIN_BARY_COORD_NO_PERSP_KHR));
    try std.testing.expect(hasPlainDecoration(spirv, DECO_PER_VERTEX_KHR));
}

test "strict: barycentric per-vertex interface block array (pervertexEXT in Foo {...} foo[3]) is modeled faithfully" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_fragment_shader_barycentric : require
        \\layout(location = 0) out vec2 value;
        \\layout(location = 0) pervertexEXT in vec2 vUV[3];
        \\layout(location = 2) pervertexEXT in Foo
        \\{
        \\    vec2 a;
        \\    vec2 b;
        \\} foo[3];
        \\void main () {
        \\    value = gl_BaryCoordEXT.x * vUV[0] + gl_BaryCoordEXT.y * vUV[1] + gl_BaryCoordEXT.z * vUV[2];
        \\    value += gl_BaryCoordEXT.x * foo[0].a;
        \\    value += gl_BaryCoordEXT.y * foo[0].b;
        \\    value += gl_BaryCoordEXT.z * foo[1].a;
        \\}
    ;
    _ = try glslpp.compileToSPIRVStrict(alloc, src, .{ .stage = .fragment });
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expect(hasCapability(spirv, CAP_FRAGMENT_BARYCENTRIC_KHR));
    try std.testing.expect(hasBuiltInDecoration(spirv, BUILTIN_BARY_COORD_KHR));
    // Both per-vertex inputs — the plain array `vUV` AND the per-vertex
    // INTERFACE-BLOCK array `foo` — must each carry PerVertexKHR. Asserting a
    // count >= 2 proves the block instance (not just the plain array) is
    // decorated, i.e. the qualifier survives the interface-block path.
    try std.testing.expectEqual(@as(usize, 2), countPlainDecoration(spirv, DECO_PER_VERTEX_KHR));
    // NOTE: the `OpDecorate %Foo Block` decoration the oracle emits is a
    // SEPARATE, pre-existing gap that affects ALL fragment input/output
    // interface blocks (verified: a non-barycentric `in Foo {...} foo;` also
    // lacks it) — it is out of scope for this barycentric fix (the task scopes
    // the interface-block-array handling as already-separate). Tracked apart.
}

/// Scan for `OpCapability <cap>` (Op 17, word_count 2).
fn hasCapability(spirv: []const u32, cap: u32) bool {
    if (spirv.len < 5) return false;
    var i: usize = 5;
    while (i < spirv.len) {
        const word = spirv[i];
        const op: u16 = @truncate(word & 0xFFFF);
        const wc: usize = @as(u16, @truncate(word >> 16));
        if (wc == 0) return false;
        if (op == 17 and wc == 2 and i + 1 < spirv.len and spirv[i + 1] == cap) return true;
        i += wc;
    }
    return false;
}

/// Scan for `OpDecorate <target> BuiltIn <builtin>` (Op 71, BuiltIn=11 at word+2,
/// builtin value at word+3).
fn hasBuiltInDecoration(spirv: []const u32, builtin: u32) bool {
    if (spirv.len < 5) return false;
    var i: usize = 5;
    while (i < spirv.len) {
        const word = spirv[i];
        const op: u16 = @truncate(word & 0xFFFF);
        const wc: usize = @as(u16, @truncate(word >> 16));
        if (wc == 0) return false;
        if (op == 71 and wc >= 4 and spirv[i + 2] == 11 and spirv[i + 3] == builtin) return true;
        i += wc;
    }
    return false;
}

/// Scan for `OpDecorate <target> <decoration>` with NO extra operand
/// (Op 71, word_count 3) — e.g. PerVertexKHR (5285) or Block (2).
fn hasPlainDecoration(spirv: []const u32, decoration: u32) bool {
    if (spirv.len < 5) return false;
    var i: usize = 5;
    while (i < spirv.len) {
        const word = spirv[i];
        const op: u16 = @truncate(word & 0xFFFF);
        const wc: usize = @as(u16, @truncate(word >> 16));
        if (wc == 0) return false;
        if (op == 71 and wc == 3 and spirv[i + 2] == decoration) return true;
        i += wc;
    }
    return false;
}

/// Count `OpDecorate <target> <decoration>` (Op 71, word_count 3) occurrences.
fn countPlainDecoration(spirv: []const u32, decoration: u32) usize {
    if (spirv.len < 5) return 0;
    var n: usize = 0;
    var i: usize = 5;
    while (i < spirv.len) {
        const word = spirv[i];
        const op: u16 = @truncate(word & 0xFFFF);
        const wc: usize = @as(u16, @truncate(word >> 16));
        if (wc == 0) return n;
        if (op == 71 and wc == 3 and spirv[i + 2] == decoration) n += 1;
        i += wc;
    }
    return n;
}

fn containsOpcode(spirv: []const u32, opcode: u16) bool {
    if (spirv.len < 5) return false;
    var i: usize = 5;
    while (i < spirv.len) {
        const word = spirv[i];
        const op: u16 = @truncate(word & 0xFFFF);
        const word_count: usize = @as(u16, @truncate(word >> 16));
        if (word_count == 0) return false;
        if (op == opcode) return true;
        i += word_count;
    }
    return false;
}
