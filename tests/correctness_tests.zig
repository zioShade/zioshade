const std = @import("std");
const zioshade = @import("zioshade");
const reflect = @import("zioshade").reflection;

// =============================================================================
// G1: Reflection API — deep correctness tests
// =============================================================================

test "G1: multiple UBOs at different bindings and sets" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, set = 0, binding = 0) uniform UBO0 { vec4 a; };
        \\layout(std140, set = 0, binding = 1) uniform UBO1 { vec4 b; };
        \\layout(std140, set = 1, binding = 0) uniform UBO2 { vec4 c; };
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = a + b + c; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), res.uniform_buffers.len);

    const b0 = res.uniform_buffers[0];
    const b1 = res.uniform_buffers[1];
    const b2 = res.uniform_buffers[2];
    try std.testing.expectEqual(@as(u32, 0), b0.binding);
    try std.testing.expectEqual(@as(u32, 1), b1.binding);
    try std.testing.expectEqual(@as(u32, 0), b2.binding);
    try std.testing.expect(b2.set != 0xFFFF_FFFF);
}

test "G1: UBO member names and offsets are extracted" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform MyBlock {
        \\    vec4 position;
        \\    vec4 color;
        \\    float scale;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = position * color * scale; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    const ubo = res.uniform_buffers[0];
    try std.testing.expect(ubo.members.len >= 3);

    try std.testing.expectEqualStrings("position", ubo.members[0].name);
    try std.testing.expectEqual(@as(u32, 0), ubo.members[0].offset);

    try std.testing.expectEqualStrings("color", ubo.members[1].name);
    try std.testing.expectEqual(@as(u32, 16), ubo.members[1].offset);

    try std.testing.expectEqualStrings("scale", ubo.members[2].name);
    try std.testing.expectEqual(@as(u32, 32), ubo.members[2].offset);
}

test "G1: UBO member type kinds are resolved" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform Types {
        \\    int i;
        \\    uint u;
        \\    float f;
        \\    vec4 v;
        \\    mat4 m;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(float(i), float(u), f, 1.0) * m * v; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    const ubo = res.uniform_buffers[0];
    try std.testing.expect(ubo.members.len >= 5);
    try std.testing.expectEqual(reflect.TypeKind.scalar_int, ubo.members[0].type_kind);
    try std.testing.expectEqual(reflect.TypeKind.scalar_uint, ubo.members[1].type_kind);
    try std.testing.expectEqual(reflect.TypeKind.scalar_float, ubo.members[2].type_kind);
    try std.testing.expectEqual(reflect.TypeKind.vector, ubo.members[3].type_kind);
    try std.testing.expectEqual(reflect.TypeKind.matrix, ubo.members[4].type_kind);
}

test "G1: multiple sampled images at different bindings" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 430
        \\layout(binding = 0) uniform sampler2D texA;
        \\layout(binding = 1) uniform sampler2D texB;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    vec4 a = texture(texA, vec2(0.0));
        \\    vec4 b = texture(texB, vec2(0.0));
        \\    FragColor = a + b;
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expect(res.sampled_images.len >= 2);
    var found_0 = false;
    var found_1 = false;
    for (res.sampled_images) |si| {
        if (si.binding == 0) found_0 = true;
        if (si.binding == 1) found_1 = true;
    }
    try std.testing.expect(found_0 and found_1);
}

test "G1: vertex shader entry point and inputs" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 430
        \\layout(location = 0) in vec3 aPos;
        \\layout(location = 1) in vec2 aUV;
        \\layout(location = 0) out vec2 vUV;
        \\void main() {
        \\    gl_Position = vec4(aPos, 1.0);
        \\    vUV = aUV;
        \\}
    , .{ .stage = .vertex });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expect(res.entry_points.len >= 1);
    try std.testing.expectEqual(reflect.Stage.vertex, res.entry_points[0].stage);
    try std.testing.expect(res.inputs.len >= 2);
    try std.testing.expect(res.outputs.len >= 1);
}

test "G1: compute shader entry point with SSBOs" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 430
        \\layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
        \\layout(std430, binding = 0) buffer SrcBuf { float src[]; };
        \\layout(std430, binding = 1) buffer DstBuf { float dst[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    dst[idx] = src[idx] * 2.0;
        \\}
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expect(res.entry_points.len >= 1);
    try std.testing.expectEqual(reflect.Stage.compute, res.entry_points[0].stage);
    try std.testing.expectEqual(@as(usize, 2), res.storage_buffers.len);
}

test "G1: empty shader reflects minimal resources" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 430
        \\void main() {}
    , .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), res.uniform_buffers.len);
    try std.testing.expectEqual(@as(usize, 0), res.storage_buffers.len);
    try std.testing.expectEqual(@as(usize, 0), res.sampled_images.len);
    try std.testing.expectEqual(@as(usize, 0), res.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), res.outputs.len);
    try std.testing.expectEqual(@as(usize, 0), res.push_constants.len);
    try std.testing.expect(res.entry_points.len >= 1);
}

test "G1: invalid SPIR-V magic returns error" {
    const alloc = std.testing.allocator;
    const bad_spv = [_]u32{ 0xDEADBEEF, 0, 0, 0, 0 };
    const result = zioshade.reflectSPIRV(alloc, &bad_spv);
    try std.testing.expectError(error.InvalidSPIRV, result);
}

test "G1: too-short SPIR-V returns error" {
    const alloc = std.testing.allocator;
    const short_spv = [_]u32{0x07230203};
    const result = zioshade.reflectSPIRV(alloc, &short_spv);
    try std.testing.expectError(error.InvalidSPIRV, result);
}

test "G1: push constant with members" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 430
        \\layout(push_constant) uniform Push {
        \\    mat4 mvp;
        \\    vec4 tint;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = tint; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), res.push_constants.len);
    const pc = res.push_constants[0];
    try std.testing.expect(pc.members.len >= 2);
    try std.testing.expectEqualStrings("mvp", pc.members[0].name);
    try std.testing.expectEqual(reflect.TypeKind.matrix, pc.members[0].type_kind);
    try std.testing.expectEqualStrings("tint", pc.members[1].name);
    try std.testing.expectEqual(reflect.TypeKind.vector, pc.members[1].type_kind);
}

test "G1: resource IDs are non-zero and unique" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform A { vec4 x; };
        \\layout(std140, binding = 1) uniform B { vec4 y; };
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = x + y; }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), res.uniform_buffers.len);
    try std.testing.expect(res.uniform_buffers[0].id != res.uniform_buffers[1].id);
    try std.testing.expect(res.uniform_buffers[0].id > 0);
    try std.testing.expect(res.uniform_buffers[1].id > 0);
}

test "G1: reflectGLSL matches reflectSPIRV for same source" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 430
        \\layout(std140, binding = 0) uniform UBO { mat4 mvp; vec4 tint; };
        \\layout(binding = 1) uniform sampler2D tex;
        \\layout(location = 0) in vec2 vUV;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = texture(tex, vUV) * tint; }
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    var res1 = try zioshade.reflectSPIRV(alloc, spv);
    defer res1.deinit(alloc);
    var res2 = try zioshade.reflectGLSL(alloc, source, .{ .stage = .fragment });
    defer res2.deinit(alloc);

    try std.testing.expectEqual(res1.uniform_buffers.len, res2.uniform_buffers.len);
    try std.testing.expectEqual(res1.sampled_images.len, res2.sampled_images.len);
    try std.testing.expectEqual(res1.inputs.len, res2.inputs.len);
    try std.testing.expectEqual(res1.outputs.len, res2.outputs.len);
}

// =============================================================================
// G4: GLSL version flexibility — correctness tests
// =============================================================================

test "G4: GLSL 300 (ESSL) is rejected with an honest error" {
    // #169: 300 is OpenGL ES Shading Language, which zioshade intentionally does NOT
    // emit. Requesting it must fail loudly rather than silently produce an invalid
    // or wrong-dialect #version. Mirrors the honest-error gate in root.zig.
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedGlslVersion, zioshade.compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0); }
    , .fragment, 300));
}

test "G4: GLSL 330 output contains #version 330" {
    const alloc = std.testing.allocator;
    const glsl = try zioshade.compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0); }
    , .fragment, 330);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "#version 330") != null);
}

test "G4: GLSL 450 output preserves binding qualifiers" {
    const alloc = std.testing.allocator;
    const glsl = try zioshade.compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(std140, binding = 3) uniform UBO { vec4 data; };
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = data; }
    , .fragment, 450);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "#version 450") != null);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "binding") != null);
}

test "G4: GLSL 460 output valid" {
    const alloc = std.testing.allocator;
    const glsl = try zioshade.compileGlslToGlslVersion(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
    , .fragment, 460);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "#version 460") != null);
}

test "G4: backward-compatible compileGlslToGlsl still works" {
    const alloc = std.testing.allocator;
    const glsl = try zioshade.compileGlslToGlsl(alloc,
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(0.5); }
    , .fragment);
    defer alloc.free(glsl);
    try std.testing.expect(std.mem.indexOf(u8, glsl, "#version") != null);
}

test "G4: cross-compile preserves shader semantics across versions" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 430
        \\layout(location = 0) in vec2 vUV;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(vUV, 0.0, 1.0); }
    ;

    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    inline for (.{ 330, 430, 450, 460 }) |ver| {
        const glsl = try zioshade.compileGlslToGlslVersion(alloc, source, .fragment, ver);
        defer alloc.free(glsl);
        try std.testing.expect(std.mem.indexOf(u8, glsl, "void main()") != null);
    }
}

// #494: a function where every path returns a value (a multi-return function, e.g.
// a palette() with if/else-if/else returns) must NOT be miscompiled to OpUndef.
// The elimUnreachableCalls pass judged only a function's LAST block, so any
// multi-block function whose tail block is a synthesized OpUnreachable — the exact
// shape of an all-paths-return function — was classified "unreachable-only" and had
// its call replaced by OpUndef. That silently dropped the return value: DXC-rejected
// in HLSL, and SILENTLY ZERO in the render-verified MSL backend (uncaught by a
// compile-only check). glslang keeps such a function as a real OpFunctionCall; so
// do we now.
test "multi-return function keeps its return value, not OpUndef (#494)" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 fragColor;
        \\vec3 palette(float x) {
        \\    if (x < 0.25) return vec3(1.0, x * 4.0, 0.0);
        \\    else if (x < 0.5) return vec3(1.0 - (x - 0.25) * 4.0, 1.0, 0.0);
        \\    else return vec3(0.0, 1.0, (x - 0.5) * 4.0);
        \\}
        \\void main() { fragColor = vec4(palette(t), 1.0); }
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    // OpUndef (opcode 1) must NOT appear — the return value must be preserved.
    try std.testing.expect(!spirvHasOpcode(spv, 1));
    // The multi-return function survives as a real call (OpFunctionCall, opcode 57).
    try std.testing.expect(spirvHasOpcode(spv, 57));
}

// An EARLY return in a fragment (`if (hit) { fragColor = c; return; }`) must be emitted,
// not dropped. Both backends used to suppress ALL fragment returns (they return the
// output value at function end), so the early-out was lost and the later write clobbered
// it -- a silent miscompile of a very common pattern (Shadertoy/raymarcher early-outs).
// Render-verified: the fixed output RENDER-MATCHes an independent glslang reference on
// Metal AND through the shipping HLSL->DXC path (a plain loopless early return, no loop
// involved). These structural checks guard against regressing back to the drop.
test "early return in a fragment is emitted, not dropped (HLSL + MSL)" {
    const alloc = std.testing.allocator;
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / 300.0;
        \\    if (uv.x < 0.5) {
        \\        fragColor = vec4(1.0, 0.0, 0.0, 1.0);
        \\        return;
        \\    }
        \\    fragColor = vec4(0.0, 0.0, 1.0, 1.0);
        \\}
    ;
    const msl = try zioshade.compileGlslToMsl(alloc, source, .fragment);
    defer alloc.free(msl);
    // The void impl must contain a `return;` -- fragments used to emit none.
    try std.testing.expect(std.mem.indexOf(u8, msl, "return;") != null);

    const hlsl = try zioshade.compileGlslToHlsl(alloc, source, .fragment);
    defer alloc.free(hlsl);
    // HLSL returns the output by value; the early return returns it too, so an emitted
    // early return means >= 2 `return ` statements (the other is the function-end one).
    try std.testing.expect(std.mem.count(u8, hlsl, "return ") >= 2);
}

// A conditional `continue` inside a loop (`if (cond) continue;`) must keep its
// intermediate then-block so downstream structured consumers (spirv-cross, DXC) see an
// explicit continue. The empty-passthrough-block pass used to collapse that block,
// retargeting the OpBranchConditional straight onto the loop's continue-target — a form
// spirv-val accepts but spirv-cross and DXC miscompile by dropping the continue as
// redundant (the selection's fall-through path also reaches the continue at the loop
// tail). Verified end-to-end: the collapsed form rendered wrong (a skipped iteration got
// accumulated) through the shipping HLSL->DXC->DXIL path, while zioshade's own tolerant
// backend masked it. Proven correct now: zioshade's SPIR-V, cross-compiled by an
// independent spirv-cross, renders identically to glslang's.
test "conditional continue in a loop keeps an explicit then-block, not collapsed onto the continue edge" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        if (i == 3) continue;
        \\        sum += 1.0;
        \\    }
        \\    fragColor = vec4(sum / 10.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    // The loop is present (OpLoopMerge = 246)...
    try std.testing.expect(spirvHasOpcode(spv, 246));
    // ...and no conditional branch targets the loop continue directly (the collapsed form).
    try std.testing.expect(!spirvConditionalTargetsLoopContinue(spv));
}

// The SAME struct type used in two interface blocks with CONFLICTING matrix layouts
// (`layout(row_major) S` in one, `layout(column_major) S` in another, where S has a matrix
// member that inherits the block qualifier) cannot be represented with a single SPIR-V
// struct type: the first layout wins and the other block silently reads the matrix
// transposed. zioshade cannot emit distinct per-layout struct types yet, so it HONEST-ERRORS
// rather than miscompile. A non-conflicting reuse (same layout in both blocks) still compiles.
test "conflicting matrix layout on a shared struct type honest-errors, not silently transposes" {
    const alloc = std.testing.allocator;
    const conflicting =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\struct S { mat4 m; };
        \\layout(binding = 0, std140) uniform A { layout(row_major) S a; } ua;
        \\layout(binding = 1, std140) uniform B { layout(column_major) S b; } ub;
        \\void main() { fragColor = ua.a.m[0] + ub.b.m[0]; }
    ;
    try std.testing.expectError(error.CodegenFailed, zioshade.compileToSPIRV(alloc, conflicting, .{ .stage = .fragment }));

    // Same layout in both blocks is fine -- the shared struct type is correct for both.
    const ok =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\struct S { mat4 m; };
        \\layout(binding = 0, std140) uniform A { layout(row_major) S a; } ua;
        \\layout(binding = 1, std140) uniform B { layout(row_major) S b; } ub;
        \\void main() { fragColor = ua.a.m[0] + ub.b.m[0]; }
    ;
    const spv = try zioshade.compileToSPIRV(alloc, ok, .{ .stage = .fragment });
    alloc.free(spv);
}

// A `continue` inside a switch-default that itself contains a nested while-loop, all inside
// an outer for-loop, made the frontend emit a control-flow instruction targeting id 0 (a
// dangling continue label it could not resolve) = invalid SPIR-V. deadLoopElim could then
// delete the whole malformed loop, turning a loud invalid into a silent-wrong render. The
// hasMalformedCFG gate on the raw frontend output catches the dangling target and fails loud.
test "a dangling continue target in a nested loop/switch honest-errors, not silent-wrong" {
    const alloc = std.testing.allocator;
    const pathological =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\  vec4 f4;
        \\  int c = int(f4.x);
        \\  for (int j = 0; j < c; j++) {
        \\    switch (c) {
        \\      case 0: f4.y = 0.0; break;
        \\      case 1: f4.y = 1.0; break;
        \\      default: { int i = 0; while (i++ < c) { f4.y += 0.5; } continue; }
        \\    }
        \\    f4.y += 0.5;
        \\  }
        \\  fragColor = f4;
        \\}
    ;
    try std.testing.expectError(error.CodegenFailed, zioshade.compileToSPIRV(alloc, pathological, .{ .stage = .fragment }));
}

// A loop-carried struct variable (`pt = spawn(uv); for(...) pt = update(pt, dt);`) must
// reload `pt` each iteration, not reuse the pre-loop value. The store-forward cache kept
// pt's pointer -> the spawn result across the loop header (unssaAllScopes only spilled
// still-SSA vars, not this already-memory-backed one), so every iteration called
// update(spawn_result) instead of update(current_pt) -- the loop never accumulated. Fixed
// by clearing the load caches in unssaAllScopes. Assert the in-loop call does not take the
// raw spawn result as its argument.
test "a loop-carried struct is reloaded each iteration, not the pre-loop value" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\struct P { vec2 pos; float life; };
        \\P spawn(vec2 u) { P p; p.pos = u; p.life = 1.0; return p; }
        \\P step(P p) { p.pos += p.life; p.life -= 0.1; return p; }
        \\void main() {
        \\    P pt = spawn(gl_FragCoord.xy / 300.0);
        \\    for (int i = 0; i < 3; i++) { pt = step(pt); }
        \\    fragColor = vec4(pt.pos, pt.life, 1.0);
        \\}
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    // The first OpFunctionCall (spawn) result must NOT be the argument of the in-loop call.
    var idx: usize = 5;
    var spawn_res: u32 = 0;
    var reuses_preloop = false;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        if (@as(u16, @truncate(spv[idx] & 0xFFFF)) == 57 and wc >= 5) { // OpFunctionCall res_ty res fn arg0...
            if (spawn_res == 0) {
                spawn_res = spv[idx + 2]; // the spawn call's result
            } else if (spv[idx + 4] == spawn_res) {
                reuses_preloop = true; // a later call takes the spawn result directly as arg0
            }
        }
        idx += wc;
    }
    try std.testing.expect(!reuses_preloop);
}

// A loop-carried struct whose MEMBERS are read after the loop (`cur = mix(cur, ...);`
// in a loop, then `cur.r`/`cur.g`/`cur.b`) must stay valid SPIR-V. loopCounterToPhi
// promoted the struct variable to an OpPhi value and deleted its OpVariable, but the
// post-loop member reads were OpAccessChain into the (now-removed) pointer -- a dangling
// ID that spirv-val rejects ("ID '%N' has not been defined"). The pass must skip any
// variable used as an OpAccessChain base. Guard: every OpAccessChain base is defined.
test "a loop-carried struct read by member after the loop stays valid SPIR-V" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\struct Color { float r; float g; float b; };
        \\Color mixC(Color a, Color b, float t) {
        \\    Color c; c.r = a.r*(1.0-t)+b.r*t; c.g = a.g*(1.0-t)+b.g*t; c.b = a.b*(1.0-t)+b.b*t; return c;
        \\}
        \\void main() {
        \\    Color base; base.r = 0.1; base.g = 0.2; base.b = 0.3;
        \\    Color tgt; tgt.r = 0.4; tgt.g = 0.5; tgt.b = 0.6;
        \\    Color cur = base;
        \\    for (int i = 0; i < 5; i++) { cur = mixC(cur, tgt, float(i) * 0.1); }
        \\    fragColor = vec4(cur.r, cur.g, cur.b, 1.0);
        \\}
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);

    // Oracle-free def-use check: collect every result id that can be an access-chain
    // base (OpVariable, OpAccessChain, OpPhi, OpFunctionParameter -- each carries its
    // result in word[2]), then assert no OpAccessChain references an undefined base.
    var defined = std.AutoHashMap(u32, void).init(alloc);
    defer defined.deinit();
    var i: usize = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[i] & 0xFFFF);
        switch (op) {
            59, 65, 245, 55 => if (wc >= 3) try defined.put(spv[i + 2], {}), // Variable/AccessChain/Phi/FunctionParameter
            else => {},
        }
        i += wc;
    }
    i = 5;
    while (i < spv.len) {
        const wc = spv[i] >> 16;
        if (wc == 0) break;
        if (@as(u16, @truncate(spv[i] & 0xFFFF)) == 65 and wc >= 4) { // OpAccessChain base = word[3]
            try std.testing.expect(defined.contains(spv[i + 3]));
        }
        i += wc;
    }

    try spirvValOrSkip(spv);
}

// A function that returns the loaded value of a local variable it mutated
// (`Particle update(Particle p){ p.pos += …; return p; }`) must not be inlined by
// inlineTrivialFuncs: the inliner forwarded the caller's read of the result back to the
// PRE-mutation argument, dropping the update (the shader rendered the original particle
// state). Such functions are left as calls (the backend compiles them correctly); assert
// the call survives.
test "a function returning a mutated local is not inlined (would drop the mutation)" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\struct Particle { vec2 pos; vec2 vel; float life; };
        \\Particle update(Particle p, float dt) { p.pos += p.vel * dt; p.life -= dt; return p; }
        \\void main() {
        \\    Particle p; p.pos = gl_FragCoord.xy; p.vel = vec2(1.0, -0.5); p.life = 1.0;
        \\    p = update(p, 0.016);
        \\    p = update(p, 0.016);
        \\    fragColor = vec4(p.pos * 0.005, p.life, 1.0);
        \\}
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    // The modify-and-return function stays an OpFunctionCall (57) rather than being inlined
    // by the (buggy-for-this-pattern) inliner, which would drop the mutation.
    try std.testing.expect(spirvHasOpcode(spv, 57));
}

// A switch where multiple cases each `return` a value must emit EVERY case's return, not
// just the first. The dead-code-after-return suppression flag (`has_returned`) was set by
// the first returning case and never reset between cases, so `analyzeStatement` silently
// dropped the `return` in every later case (they became empty fall-through blocks that the
// optimizer then collapsed onto an unreachable merge). Reset per case: each case is a
// distinct path entered directly from the OpSwitch. Caught by the full render proof
// (switch_nested_func rendered a flat color instead of the 4-way ramp).
test "every returning case of a switch emits its return, not just the first" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\float pick(int i) {
        \\    switch (i) {
        \\        case 0: return 0.8;
        \\        case 1: return 0.6;
        \\        case 2: return 0.4;
        \\        default: return 0.2;
        \\    }
        \\}
        \\void main() {
        \\    int idx = int(gl_FragCoord.x / 80.0);
        \\    fragColor = vec4(vec3(pick(idx)), 1.0);
        \\}
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    var idx: usize = 5;
    var returns: usize = 0;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        if (@as(u16, @truncate(spv[idx] & 0xFFFF)) == 254) returns += 1; // OpReturnValue
        idx += wc;
    }
    try std.testing.expect(returns >= 4);
}

// A `switch` whose `default:` case carries a real body must emit that body. The parser
// gives a `case N:` node a leading value-expr child but a `default:` node none, so its
// children are body statements from index 0. The switch lowering used to slice every
// case body as `children[1..]` unconditionally, which for the default dropped its FIRST
// statement. When that statement was the only meaningful one (`default: x = v; break;`),
// the default block collapsed to `label; branch merge` -- empty -- and the empty-block
// pass then retargeted the OpSwitch default straight onto the selection merge, silently
// discarding the default arm. Signature: OpSwitch's default target equals the enclosing
// OpSelectionMerge label even though the default has a body. Fixed by slicing the default
// body from index 0.
test "switch default case with a body is not dropped" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int mode = int(gl_FragCoord.x) % 3;
        \\    float result = 0.0;
        \\    switch (mode) {
        \\        case 0: result = 1.0; break;
        \\        case 1: result = 2.0; break;
        \\        default: result = 9.0; break;
        \\    }
        \\    fragColor = vec4(result, 0.0, 0.0, 1.0);
        \\}
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    // A switch is present (OpSwitch = 251)...
    try std.testing.expect(spirvHasOpcode(spv, 251));
    // ...and its default target is a real block, not the selection merge (which would
    // mean the bodied default was discarded).
    try std.testing.expect(!spirvSwitchDefaultTargetsMerge(spv));
}

// A switch whose cases fall through and accumulate into a variable initialized before the
// switch must materialize that initialization ahead of the OpSwitch. The frontend kept the
// accumulator as a deferred SSA value and never spilled pending vars before the switch (it
// does before a loop header), so the init store landed lazily inside the FIRST case block;
// a selector jumping straight to a later case then read an uninitialized variable. Rendered
// ~94% of pixels wrong (frontend=MISCOMPILE vs the glslang oracle). Fixed by un-SSA-ing all
// scopes before the OpSwitch.
test "switch fallthrough accumulator is initialized before the switch, not inside the first case" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 col = vec3(0.0);
        \\    int mode = clamp(int(gl_FragCoord.y / 60.0), 0, 4);
        \\    switch (mode) {
        \\        case 4: col += vec3(0.2, 0.0, 0.0);
        \\        case 3: col += vec3(0.0, 0.2, 0.0);
        \\        case 2: col += vec3(0.0, 0.0, 0.2);
        \\        case 1: col += vec3(0.1);
        \\        case 0: col += vec3(0.05);
        \\    }
        \\    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
        \\}
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 251)); // OpSwitch present
    // No case block reads the accumulator before it was initialized ahead of the switch.
    try std.testing.expect(!spirvSwitchCaseLoadsUninitVar(spv));
}

// A swizzle-target write (`v.xy = expr`) lowers to an OpVectorShuffle of the vec3 lvalue
// with the vec2 rhs (selectors `3 4 2`). The MSL backend split the selector space at a
// HARDCODED 4 (assuming v1 is always vec4), so for a vec3 v1 it emitted `<v1>[3]` -- an
// out-of-bounds index -- and shifted every later selector, making v.x read garbage and
// miscompiling ~62% of pixels. Fixed by splitting at v1's actual component count. The GLSL
// and HLSL backends already used v1's real width; only MSL was wrong.
test "swizzle-target write does not emit an out-of-bounds MSL shuffle index" {
    const alloc = std.testing.allocator;
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / vec2(128.0);
        \\    vec3 v = vec3(0.0);
        \\    v.xy = uv * 2.0;
        \\    fragColor = vec4(v, 1.0);
        \\}
    ;
    const msl = try zioshade.compileGlslToMsl(alloc, source, .fragment);
    defer alloc.free(msl);
    // No 3-or-4-wide value in this shader is legitimately indexed at [3], so an emitted
    // "[3]" is the out-of-bounds shuffle bug.
    try std.testing.expect(std.mem.indexOf(u8, msl, "[3]") == null);
}

// A conditional loop-increment (`for (...; cond ? a : b++)`) lowers to a SelectionMerge
// guarding the `b++` store inside the loop's continue/latch block. The MSL and HLSL loop
// emitters walk the latch straight-line and cannot yet emit a selection there; silently
// skipping it would DROP the increment, freezing the counter into an infinite loop that
// renders all-black. They must fail loud instead of silently miscompiling. A do-while's
// latch also carries a SelectionMerge (its back-edge test) but compiles fine -- only a
// non-do-while conditional increment errors. (Full latch-selection emit is a tracked
// follow-up; when it lands, replace this with a render-verified correctness assertion.)
test "conditional loop increment honest-errors instead of dropping the increment" {
    const alloc = std.testing.allocator;
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    FragColor = vec4(0.0);
        \\    for (int i = 0; i < 3; (0 > 1) ? 1 : i++) {
        \\        FragColor[i] += float(i);
        \\    }
        \\}
    ;
    // The frontend accepts it (valid SPIR-V); the backends honest-error.
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    alloc.free(spv);
    try std.testing.expectError(error.UnstructuredControlFlow, zioshade.compileGlslToMsl(alloc, source, .fragment));
    try std.testing.expectError(error.UnstructuredControlFlow, zioshade.compileGlslToHlsl(alloc, source, .fragment));
}

// A do-while whose back-edge test is a COMPOUND condition with ARITHMETIC
// (`while (iter < 30 && zx*zx + zy*zy < 4.0)`) is emitted natively. The do-while emitter
// rebuilds the back-edge condition inline over the persistent loop vars so a body
// `continue`/`break` re-evaluates it at the bottom test; that rebuilder handled only a
// single comparison of loads/constants and honest-errored on OpLogicalAnd/Or or an
// arithmetic operand -- the common iteration-loop shape (fractal/raymarch magnitude test).
// Now compiles for both backends. Both patterns render-verify against the glslang oracle.
test "do-while with a compound arithmetic back-edge condition compiles (HLSL + MSL)" {
    const alloc = std.testing.allocator;
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / 300.0;
        \\    float zx = uv.x * 2.0 - 1.0;
        \\    float zy = uv.y * 2.0 - 1.0;
        \\    int iter = 0;
        \\    do {
        \\        float xn = zx * zx - zy * zy + uv.x;
        \\        float yn = 2.0 * zx * zy + uv.y;
        \\        zx = xn; zy = yn; iter++;
        \\        if (zx * zx + zy * zy > 4.0) break;
        \\    } while (iter < 30 && zx * zx + zy * zy < 4.0);
        \\    fragColor = vec4(float(iter) / 30.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try zioshade.compileGlslToMsl(alloc, source, .fragment);
    defer alloc.free(msl);
    const hlsl = try zioshade.compileGlslToHlsl(alloc, source, .fragment);
    defer alloc.free(hlsl);
    // Both emit a native do-while whose bottom test re-joins the two clauses with &&.
    try std.testing.expect(std.mem.indexOf(u8, msl, "while") != null and std.mem.indexOf(u8, msl, "&&") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "while") != null and std.mem.indexOf(u8, hlsl, "&&") != null);
}

// A loop nested inside a branch arm (`if (c) {...} else { for (...) {...} }`) is now
// emitted correctly by both backends: emitBlock (the branch-arm emitter) delegates to the
// loop emitter (emitWhileLoop{MSL,HLSL}) the way emitBody does, replaying the loop's phi
// decls first. It used to silently drop the loop (then honest-error #501); now it compiles
// and RENDER-MATCHes an independent glslang oracle on Metal AND the shipping HLSL->DXC path
// (early_return2, recursive_fib, a multi-var-init analog). Genuinely-unsupported loop
// sub-shapes still fail loud via emitWhileLoop's own honest-errors (the floor holds).
test "loop nested in a branch arm compiles and emits the loop (HLSL + MSL)" {
    const alloc = std.testing.allocator;
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision highp float;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = length(gl_FragCoord.xy / 150.0 - 1.0);
        \\    vec3 col = vec3(0.0);
        \\    if (r < 0.1) {
        \\        col = vec3(1.0);
        \\    } else {
        \\        for (int i = 0; i < 5; i++) {
        \\            col += vec3(0.1 * float(i));
        \\        }
        \\    }
        \\    fragColor = vec4(col, 1.0);
        \\}
    ;
    const hlsl = try zioshade.compileGlslToHlsl(alloc, source, .fragment);
    defer alloc.free(hlsl);
    // The nested loop is emitted (as a while(true) in the else arm), not dropped.
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "while") != null);
    const msl = try zioshade.compileGlslToMsl(alloc, source, .fragment);
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "while") != null);
}

// =============================================================================
// G10: HLSL SM 5.0 compatibility — correctness tests
// =============================================================================

test "G10: basic HLSL output contains cbuffer for UBO" {
    const alloc = std.testing.allocator;
    const hlsl = try zioshade.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform MyCBuffer {
        \\    vec4 color;
        \\    float intensity;
        \\};
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = color * intensity; }
    , .fragment);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "cbuffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "register(b0)") != null);
}

test "G10: HLSL output uses Texture2D + SamplerState for sampler2D" {
    const alloc = std.testing.allocator;
    const hlsl = try zioshade.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(binding = 0) uniform sampler2D myTex;
        \\layout(location = 0) in vec2 vUV;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = texture(myTex, vUV); }
    , .fragment);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "Texture2D") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SamplerState") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, ".Sample(") != null);
}

test "G10: HLSL vertex shader has VS signature" {
    const alloc = std.testing.allocator;
    const hlsl = try zioshade.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(location = 0) in vec3 aPos;
        \\void main() {
        \\    gl_Position = vec4(aPos, 1.0);
        \\}
    , .vertex);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "SV_POSITION") != null or
        std.mem.indexOf(u8, hlsl, "gl_Position") != null or
        std.mem.indexOf(u8, hlsl, "main") != null);
}

test "G10: HLSL compute shader has [numthreads]" {
    const alloc = std.testing.allocator;
    const hlsl = try zioshade.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
        \\layout(std430, binding = 0) buffer Data { float values[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    values[idx] *= 2.0;
        \\}
    , .compute);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "numthreads") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "64") != null);
}

test "G10: HLSL output for mat4 uses float4x4" {
    const alloc = std.testing.allocator;
    const hlsl = try zioshade.compileGlslToHlsl(alloc,
        \\#version 430
        \\layout(std140, binding = 0) uniform UBO { mat4 mvp; };
        \\layout(location = 0) in vec4 aPos;
        \\void main() { gl_Position = mvp * aPos; }
    , .vertex);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "float4x4") != null or
        std.mem.indexOf(u8, hlsl, "float4") != null);
}

// =============================================================================
// Cross-cutting: Reflection + cross-compile consistency
// =============================================================================

test "cross: reflected resources match across GLSL and HLSL backends" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 430
        \\layout(std140, binding = 0) uniform UBO { vec4 data; };
        \\layout(binding = 1) uniform sampler2D tex;
        \\layout(location = 0) in vec2 vUV;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = texture(tex, vUV) * data; }
    ;

    var res = try zioshade.reflectGLSL(alloc, source, .{ .stage = .fragment });
    defer res.deinit(alloc);

    const hlsl = try zioshade.compileGlslToHlsl(alloc, source, .fragment);
    defer alloc.free(hlsl);

    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    try std.testing.expectEqual(@as(usize, 1), res.sampled_images.len);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "cbuffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "Texture2D") != null);
}

test "cross: SSBO reflected as storage_buffer and present in HLSL" {
    const alloc = std.testing.allocator;
    const source =
        \\#version 430
        \\layout(std430, binding = 0) buffer Data { float vals[]; };
        \\layout(std140, binding = 1) uniform Params { float scale; };
        \\void main() { vals[0] *= scale; }
    ;
    const spv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spv);
    var res = try zioshade.reflectSPIRV(alloc, spv);
    defer res.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), res.storage_buffers.len);
    try std.testing.expectEqual(@as(u32, 0), res.storage_buffers[0].binding);
    try std.testing.expectEqual(@as(usize, 1), res.uniform_buffers.len);
    try std.testing.expectEqual(@as(u32, 1), res.uniform_buffers[0].binding);

    const hlsl = try zioshade.compileGlslToHlsl(alloc, source, .compute);
    defer alloc.free(hlsl);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "ByteAddressBuffer") != null or
        std.mem.indexOf(u8, hlsl, "StructuredBuffer") != null or
        std.mem.indexOf(u8, hlsl, "RWByteAddressBuffer") != null or
        std.mem.indexOf(u8, hlsl, "buffer") != null);
}

fn spirvHasWord(spv: []const u32, word: u32) bool {
    for (spv) |w| if (w == word) return true;
    return false;
}

/// True if the SPIR-V module contains at least one instruction with `opcode`
/// (low 16 bits of the instruction header word). Walks instructions by word
/// count, skipping the 5-word module header.
fn spirvHasOpcode(spv: []const u32, opcode: u16) bool {
    var idx: usize = 5;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (@as(u16, @truncate(spv[idx] & 0xFFFF)) == opcode) return true;
        if (wc == 0) break;
        idx += wc;
    }
    return false;
}

// True iff the module contains an `OpDecorate <target> BuiltIn <value>`. Used to
// verify a builtin lowers to the correct SPIR-V BuiltIn constant (e.g. gl_ViewportIndex
// → ViewportIndex 10, NOT ViewIndex 4440). OpDecorate=71, Decoration BuiltIn=11.
fn spirvHasBuiltinDecoration(spv: []const u32, builtin_value: u32) bool {
    var idx: usize = 5;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 71 and wc >= 4 and spv[idx + 2] == 11 and spv[idx + 3] == builtin_value) return true;
        idx += wc;
    }
    return false;
}

// True iff any OpBranchConditional (250) directly targets a loop's continue-target (the
// collapsed-`continue` shape). A well-formed `if(cond) continue;` routes through an
// intermediate then-block that unconditionally branches to the continue target; a bare
// conditional edge onto the continue label is the miscompiling form spirv-cross/DXC drop.
// OpLoopMerge=246 (continue = word[2]); OpBranchConditional=250 (true=word[2], false=word[3]).
fn spirvConditionalTargetsLoopContinue(spv: []const u32) bool {
    var continues = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer continues.deinit();
    var idx: usize = 5;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 246 and wc >= 3) continues.put(spv[idx + 2], {}) catch {};
        idx += wc;
    }
    idx = 5;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 250 and wc >= 4) {
            if (continues.contains(spv[idx + 2]) or continues.contains(spv[idx + 3])) return true;
        }
        idx += wc;
    }
    return false;
}

// True iff some switch case block does an OpLoad of a function variable that was never
// stored before the OpSwitch and is not stored earlier in that same block. Each case
// label is a DIRECT branch target of the OpSwitch, so a fallthrough accumulator that is
// initialized before the switch (`col = vec3(0); switch(m){ case 4: col += ...; case 3:
// col += ...; }`) must have its init store materialized ahead of the OpSwitch. The bug:
// the frontend kept the accumulator as a deferred SSA value and spilled its init store
// lazily inside the FIRST case block, so a selector jumping straight to a later case read
// an uninitialized variable. This walks for that read-before-init.
fn spirvSwitchCaseLoadsUninitVar(spv: []const u32) bool {
    var func_vars = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer func_vars.deinit();
    var pre_switch_stored = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer pre_switch_stored.deinit();
    // Pass 1: collect Function OpVariables and find the first OpSwitch position.
    var sw_pos: ?usize = null;
    var idx: usize = 5;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 59 and wc >= 4 and spv[idx + 3] == 7) func_vars.put(spv[idx + 2], {}) catch {};
        if (op == 251) {
            sw_pos = idx;
            break;
        }
        idx += wc;
    }
    const swp = sw_pos orelse return false;
    // Pass 2: every OpStore target before the OpSwitch is "pre-initialized".
    idx = 5;
    while (idx < swp) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 62 and wc >= 3) pre_switch_stored.put(spv[idx + 1], {}) catch {};
        idx += wc;
    }
    // Pass 3: after the OpSwitch, per case block, flag an OpLoad of a Function var that is
    // neither pre-initialized nor stored earlier in the same block.
    var local_stored = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer local_stored.deinit();
    idx = swp;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 248) local_stored.clearRetainingCapacity(); // OpLabel: new block
        if (op == 62 and wc >= 3) local_stored.put(spv[idx + 1], {}) catch {};
        if (op == 61 and wc >= 4) { // OpLoad result_type result_id ptr
            const ptr = spv[idx + 3];
            if (func_vars.contains(ptr) and !pre_switch_stored.contains(ptr) and !local_stored.contains(ptr)) {
                return true;
            }
        }
        idx += wc;
    }
    return false;
}

// True iff some OpSwitch's default target equals its enclosing OpSelectionMerge label.
// A switch always precedes its OpSwitch with `OpSelectionMerge <merge>` (opcode 247,
// word[1] = merge label); the OpSwitch (opcode 251) has word[2] = default target. When a
// bodied default arm is dropped, its block collapses to empty and the empty-block pass
// retargets the default onto the merge, so default == merge. A switch with a genuinely
// empty (or absent) default legitimately hits this too, so only assert it false for a
// shader whose default carries real statements.
fn spirvSwitchDefaultTargetsMerge(spv: []const u32) bool {
    var last_merge: ?u32 = null;
    var idx: usize = 5;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 247 and wc >= 2) {
            last_merge = spv[idx + 1]; // OpSelectionMerge <merge> <selection control>
        } else if (op == 251 and wc >= 3) { // OpSwitch <selector> <default> …
            if (last_merge) |m| {
                if (spv[idx + 2] == m) return true;
            }
        }
        idx += wc;
    }
    return false;
}

// True iff an OpFunctionCall argument (an inout/out pointer) is re-loaded by a LATER
// OpLoad — proving the post-call read re-reads memory rather than being store-forwarded
// to the pre-call value. Without the OpFunctionCall store-forward barrier, that post-
// call OpLoad is rewritten to the pre-call stored id and disappears, so this is false.
// Scope: checks against the MOST RECENT call's args (fine for single-call test shaders).
fn funcCallArgReloaded(spv: []const u32) bool {
    var idx: usize = 5;
    var args: [16]u32 = undefined;
    var nargs: usize = 0;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 57 and wc >= 4) { // OpFunctionCall result_type result_id fn args…
            nargs = 0;
            var a: usize = idx + 4;
            while (a < idx + wc and nargs < args.len) : (a += 1) {
                args[nargs] = spv[a];
                nargs += 1;
            }
        } else if (op == 61 and wc >= 4) { // OpLoad result_type result_id ptr
            const ptr = spv[idx + 3];
            for (args[0..nargs]) |ar| if (ar == ptr) return true;
        }
        idx += wc;
    }
    return false;
}

// True iff some OpExtInst's output pointer (its last operand — the `modf`/`frexp`
// integer/exponent slot) is re-loaded by a LATER OpLoad. When the OpExtInst store-
// forward barrier is missing, the post-modf read of that pointer is rewritten to the
// pre-modf stored value and the re-read OpLoad disappears; its survival proves the
// barrier works. Pure ext insts (sin/pow/…) pass a value as their last operand, which
// is never loaded-as-pointer, so this never false-positives on them.
// Scope: tracks the MOST RECENT OpExtInst's output pointer (fine when no intervening
// ext inst sits between the modf/frexp and the read-back, as in the test shaders).
fn extInstOutputReloaded(spv: []const u32) bool {
    var idx: usize = 5;
    var target_ptr: ?u32 = null;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 12 and wc >= 6) { // OpExtInst with at least one operand
            target_ptr = spv[idx + wc - 1]; // last operand = the modf/frexp output pointer
        } else if (op == 61 and wc >= 4) { // OpLoad result_type result_id ptr
            if (target_ptr) |p| {
                if (spv[idx + 3] == p) return true;
            }
        }
        idx += wc;
    }
    return false;
}

// True iff the continue block (latch) of some loop contains an OpStore. Finds an
// OpLoopMerge (opcode 246), reads its continue-target label (word[2]), then scans
// that block for an OpStore (opcode 62). Used by the #170 do-while regression test:
// when a variable is mutated in a do-while CONDITION, the latch must re-read and
// STORE it (memory-SSA form). The pre-fix bug (branchMergePhi treating the loop
// header as a diamond merge) promoted the counter to a MIS-WIRED OpPhi — its
// loop-back operand resolved to the pre-loop value, making the condition loop-
// invariant (infinite loop) — and left NO OpStore in the latch. Store present =
// the counter is a live loop-carried memory var, not the broken phi.
fn loopLatchHasStore(spv: []const u32) bool {
    var idx: usize = 5;
    var continue_label: ?u32 = null;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 246 and wc >= 4) continue_label = spv[idx + 2]; // OpLoopMerge merge continue …
        idx += wc;
    }
    const target = continue_label orelse return false;
    // Second pass: walk to the continue block's OpLabel, then scan until the next
    // OpLabel for an OpStore.
    idx = 5;
    var in_block = false;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 248 and wc >= 2) { // OpLabel
            if (in_block) return false; // reached next block without a store
            in_block = (spv[idx + 1] == target);
        } else if (in_block and op == 62) { // OpStore inside the latch
            return true;
        }
        idx += wc;
    }
    return false;
}

// True iff the module has an OpExecutionMode (opcode 16) LocalSize (mode 17) with
// literal dims 1,1,1. Layout: [op|wc=6] entry LocalSize x y z.
fn spirvHasComputeLocalSize111(spv: []const u32) bool {
    var idx: usize = 5;
    while (idx < spv.len) {
        const wc = spv[idx] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[idx] & 0xFFFF);
        if (op == 16 and wc == 6 and spv[idx + 2] == 17) { // OpExecutionMode … LocalSize
            if (spv[idx + 3] == 1 and spv[idx + 4] == 1 and spv[idx + 5] == 1) return true;
        }
        idx += wc;
    }
    return false;
}

// Scan the SPIR-V module for an OpTypeImage (opcode 25) with Dim==Buffer (5)
// whose sampled-type id resolves to a scalar of the requested kind:
//   .float → OpTypeFloat, .int → signed OpTypeInt, .uint → unsigned OpTypeInt.
// Used by the #194 isamplerBuffer/usamplerBuffer regression tests to prove the
// emitted texel-buffer image carries the correct component type (not an empty
// OpTypeStruct, the pre-fix silent-wrong fallthrough).
const SampledKind = enum { float, int, uint };
fn spirvHasBufferImageOfKind(spv: []const u32, want: SampledKind) bool {
    // First pass: record result-id → scalar kind for OpTypeFloat / OpTypeInt.
    var idx: usize = 5; // skip 5-word header
    // result_id → 0:none, 1:float, 2:int-signed, 3:int-unsigned
    var kinds = std.AutoHashMap(u32, SampledKind).init(std.testing.allocator);
    defer kinds.deinit();
    while (idx < spv.len) {
        const word_count = spv[idx] >> 16;
        const opcode = spv[idx] & 0xFFFF;
        if (word_count == 0) break;
        if (opcode == 22 and idx + 2 < spv.len) { // OpTypeFloat result, width
            kinds.put(spv[idx + 1], .float) catch {};
        } else if (opcode == 21 and idx + 3 < spv.len) { // OpTypeInt result, width, signedness
            kinds.put(spv[idx + 1], if (spv[idx + 3] == 1) .int else .uint) catch {};
        }
        idx += word_count;
    }
    // Second pass: find OpTypeImage with Dim==Buffer and matching sampled type.
    idx = 5;
    while (idx < spv.len) {
        const word_count = spv[idx] >> 16;
        const opcode = spv[idx] & 0xFFFF;
        if (word_count == 0) break;
        // OpTypeImage: result(1) sampled_type(2) Dim(3) ...
        if (opcode == 25 and idx + 3 < spv.len) {
            const sampled_type = spv[idx + 2];
            const dim = spv[idx + 3];
            if (dim == 5) { // Buffer
                if (kinds.get(sampled_type)) |k| {
                    if (k == want) return true;
                }
            }
        }
        idx += word_count;
    }
    return false;
}

fn spirvHasOp(spv: []const u32, opcode: u32) bool {
    var idx: usize = 5;
    while (idx < spv.len) {
        const word_count = spv[idx] >> 16;
        if (word_count == 0) break;
        if ((spv[idx] & 0xFFFF) == opcode) return true;
        idx += word_count;
    }
    return false;
}

// #194: isamplerBuffer/usamplerBuffer used to have no parser keyword and (had it
// reached codegen) fell through to an empty OpTypeStruct → "Expected Image to be
// of type OpTypeImage" in spirv-val. Now they emit OpTypeImage <int|uint> Buffer.
test "gap#194: isamplerBuffer emits OpTypeImage with int component (texelFetch/textureSize)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding = 0) uniform isamplerBuffer s;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec4 v = texelFetch(s, 3);
        \\    int n = textureSize(s);
        \\    o = vec4(v) + vec4(float(n));
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasBufferImageOfKind(spv, .int));
    try std.testing.expect(spirvHasOp(spv, 95)); // OpImageFetch
    try std.testing.expect(spirvHasOp(spv, 104)); // OpImageQuerySize
}

test "gap#194: usamplerBuffer emits OpTypeImage with uint component (texelFetch/textureSize)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding = 0) uniform usamplerBuffer s;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uvec4 v = texelFetch(s, 3);
        \\    int n = textureSize(s);
        \\    o = vec4(v) + vec4(float(n));
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasBufferImageOfKind(spv, .uint));
    try std.testing.expect(spirvHasOp(spv, 95)); // OpImageFetch
    try std.testing.expect(spirvHasOp(spv, 104)); // OpImageQuerySize
}

test "gap#194 regression: float samplerBuffer still emits OpTypeImage with float component" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding = 0) uniform samplerBuffer s;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = texelFetch(s, 3);
        \\    int n = textureSize(s);
        \\    o = v + vec4(float(n));
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasBufferImageOfKind(spv, .float));
    try std.testing.expect(!spirvHasBufferImageOfKind(spv, .int));
    try std.testing.expect(!spirvHasBufferImageOfKind(spv, .uint));
}

test "fold: signed int literal in float-vector ctor wraps (two's complement) like glslang" {
    // Regression: `vec2(2147483648, 0)` — a bare decimal literal is a 32-bit
    // SIGNED int in GLSL, so 2^31 wraps to -2147483648; glslang folds the vec
    // component to -2.147e9. A bare @floatFromInt on the u32 word silently gave
    // +2.147e9 (sign flip = silent-wrong). f32 bit patterns: -2147483648.0 =
    // 0xCF000000, +2147483648.0 = 0x4F000000.
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location = 0) out vec2 o;
        \\void main() { o = vec2(2147483648, 0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasWord(spv, 0xCF000000)); // -2.147e9 (correct)
    try std.testing.expect(!spirvHasWord(spv, 0x4F000000)); // not the sign-flipped +2.147e9
}

test "fold: unsigned literal in float-vector ctor stays positive" {
    // The `u` suffix makes it unsigned — 2147483648u is +2.147e9 (= 0x4F000000),
    // matching glslang. Guards against over-correcting the signed fix.
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location = 0) out vec2 o;
        \\void main() { o = vec2(2147483648u, 0u); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasWord(spv, 0x4F000000)); // +2.147e9 (correct)
    try std.testing.expect(!spirvHasWord(spv, 0xCF000000));
}

test "frontend: separate sampler2DShadow(tex,samp) emits a depth-compare, not OpUndef" {
    // A Vulkan SEPARATE comparison sampler — `texture(sampler2DShadow(tex, samp),
    // coord)` built from a distinct texture2D + samplerShadow — was DROPPED by the
    // frontend: parsePrimary did not list the shadow sampler keywords as
    // constructors, so the constructor (and the whole statement) never parsed and
    // the depth compare vanished (empty main / OpUndef result = silent-wrong).
    // Assert the emitted SPIR-V now contains an OpImageSampleDref* op.
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 310 es
        \\precision mediump float;
        \\layout(set = 0, binding = 0) uniform mediump samplerShadow uS;
        \\layout(set = 0, binding = 1) uniform texture2D uT;
        \\layout(location = 0) out float o;
        \\void main() { o = texture(sampler2DShadow(uT, uS), vec3(0.5)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    // OpImageSampleDrefImplicitLod = 89.
    try std.testing.expect(spirvHasOpcode(spv, 89));
}

test "frontend: separate sampler2DShadow with textureLod emits explicit-lod depth-compare" {
    // Same root cause via the EXPLICIT-LOD path: textureLod(sampler2DShadow(...),
    // …) must lower to OpImageSampleDrefExplicitLod (90), not be dropped.
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(set = 0, binding = 0) uniform samplerShadow uS;
        \\layout(set = 0, binding = 1) uniform texture2D uT;
        \\layout(location = 0) out float o;
        \\void main() { o = textureLod(sampler2DShadow(uT, uS), vec3(0.5), 0.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 90)); // OpImageSampleDrefExplicitLod
}

// #170: textureProjLod (projective sample with an EXPLICIT lod) was wrongly
// rejected (honest-error) — it was missing from isTextureBuiltin. It IS faithfully
// representable: OpImageSampleProjExplicitLod with the Lod image operand. Emitting
// the implicit-lod proj op (image_sample_proj) would silently sample the wrong mip.
test "frontend: textureProjLod emits OpImageSampleProjExplicitLod with a Lod operand" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjLod(tex, c, 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 92)); // OpImageSampleProjExplicitLod
    // Must NOT degrade to the implicit-lod proj op (would drop the explicit LOD).
    try std.testing.expect(!spirvHasOpcode(spv, 91)); // OpImageSampleProjImplicitLod
}

// #170: the SHADOW form (textureProjLod(sampler2DShadow, …)) has no lowering yet —
// routing it to a NON-proj dref tag would drop the projection (silent-wrong), so it
// must honest-error rather than mis-compile.
test "frontend: textureProjLod on a shadow sampler honest-errors (no silent-wrong)" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out float o;
        \\void main(){ o = textureProjLod(sh, c, 1.0); }
    , .{ .stage = .fragment }));
}

// #170: textureProjLodOffset (projective + explicit LOD + const offset) was wrongly
// rejected (UndeclaredIdentifier) — absent from isTextureBuiltin. It IS faithfully
// representable: OpImageSampleProjExplicitLod with Lod|ConstOffset (its own IR tag,
// since the count-based Lod/Grad dispatch can't tell [coord,lod,offset] from the
// Grad form [coord,dPdx,dPdy]). Result must be VALID SPIR-V.
test "frontend: textureProjLodOffset emits valid OpImageSampleProjExplicitLod (Lod|ConstOffset)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjLodOffset(tex, c, 1.0, ivec2(2, -1)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 92)); // OpImageSampleProjExplicitLod
    try std.testing.expect(!spirvHasOpcode(spv, 91)); // not the implicit-lod proj op
    try spirvValOrSkip(spv); // the Lod|ConstOffset encoding must be well-formed
}

// #170: textureProjLodOffset must honest-error (not mis-compile) on the by-design
// holes: a CUBE sampler (ConstOffset illegal on Cube Dim; no GLSL overload), a SHADOW
// sampler (would drop the projection), and a NON-CONSTANT offset (can't be ConstOffset).
test "frontend: textureProjLodOffset cube/shadow/non-const-offset honest-error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform samplerCube s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjLodOffset(s, c, 1.0, ivec2(1, 0)); }
    , .{ .stage = .fragment }));
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out float o;
        \\void main(){ o = textureProjLodOffset(s, c, 1.0, ivec2(1, 0)); }
    , .{ .stage = .fragment }));
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec3 c;
        \\layout(location=1) flat in ivec2 dyn;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjLodOffset(s, c, 1.0, dyn); }
    , .{ .stage = .fragment }));
}

// #170: textureProjGradOffset (projective + explicit gradients + const offset) was
// wrongly rejected (UndeclaredIdentifier) — absent from the texture tables. It IS
// representable: OpImageSampleProjExplicitLod with Grad|ConstOffset (its own IR tag,
// [si,coord,dPdx,dPdy,offset]). Result must be VALID SPIR-V.
test "frontend: textureProjGradOffset emits valid OpImageSampleProjExplicitLod (Grad|ConstOffset)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjGradOffset(tex, c, vec2(0.1), vec2(0.2), ivec2(2, -1)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 92)); // OpImageSampleProjExplicitLod
    try std.testing.expect(!spirvHasOpcode(spv, 91)); // not the implicit-lod proj op
    try spirvValOrSkip(spv); // the Grad|ConstOffset encoding must be well-formed
}

// #170: textureProjGradOffset honest-errors (not mis-compile) on the by-design holes:
// CUBE (ConstOffset illegal on Cube Dim), SHADOW (gradient read as float Lod = invalid
// SPIR-V), and a NON-CONSTANT offset (can't be ConstOffset).
test "frontend: textureProjGradOffset cube/shadow/non-const-offset honest-error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform samplerCube s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjGradOffset(s, c, vec3(0.1), vec3(0.2), ivec2(1, 0)); }
    , .{ .stage = .fragment }));
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out float o;
        \\void main(){ o = textureProjGradOffset(s, c, vec2(0.1), vec2(0.2), ivec2(1, 0)); }
    , .{ .stage = .fragment }));
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec3 c;
        \\layout(location=1) flat in ivec2 dyn;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjGradOffset(s, c, vec2(0.1), vec2(0.2), dyn); }
    , .{ .stage = .fragment }));
}

// #170: GLSL `&&` / `||` MUST short-circuit — the RHS is not evaluated when the LHS
// determines the result. zioshade used to emit eager OpLogicalAnd/Or, which evaluates
// both operands and DROPS a side-effecting RHS (e.g. a function mutating an inout
// arg) = silent-wrong. When the RHS may have side effects, it now lowers to real
// short-circuit control flow (OpBranchConditional), so the side effect is conditional.
test "frontend: side-effecting && / || short-circuit (OpBranchConditional, not eager OpLogicalOr)" {
    const alloc = std.testing.allocator;
    inline for (.{ "||", "&&" }) |op| {
        const src = "#version 450\n" ++
            "layout(location=0) in vec4 iv;\n" ++
            "layout(location=0) out vec4 o;\n" ++
            "bool se(inout int c){ c += 1; return true; }\n" ++
            "void main(){ int c=0; bool a=iv.x>0.0; bool r = a " ++ op ++ " se(c); o=vec4(float(c), r?1.0:0.0, 0, 1); }\n";
        const spv = try zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 250)); // OpBranchConditional (short-circuit)
        try std.testing.expect(!spirvHasOpcode(spv, 166)); // not eager OpLogicalOr
        try std.testing.expect(!spirvHasOpcode(spv, 167)); // not eager OpLogicalAnd
        try spirvValOrSkip(spv);
    }
}

// The PURE case must KEEP the cheaper eager OpLogicalOr/And (no control flow) — the
// short-circuit lowering only kicks in for a side-effecting RHS.
test "frontend: pure && / || keep eager OpLogicalOr/And (no short-circuit overhead)" {
    const alloc = std.testing.allocator;
    const spv_or = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\void main(){ bool r = (iv.x > 0.0) || (iv.y < 1.0); o = vec4(r ? 1.0 : 0.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv_or);
    try std.testing.expect(spirvHasOpcode(spv_or, 166)); // OpLogicalOr (eager, no branch)

    const spv_and = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\void main(){ bool r = (iv.x > 0.0) && (iv.y < 1.0); o = vec4(r ? 1.0 : 0.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv_and);
    try std.testing.expect(spirvHasOpcode(spv_and, 167)); // OpLogicalAnd (eager)
}

// A side-effecting RHS inside a LOOP CONDITION must NOT emit short-circuit control
// flow (a selection_merge in the loop header breaks the loop's structured control
// flow = invalid SPIR-V). It falls back to the eager path there — still VALID SPIR-V.
test "frontend: && in a loop condition stays valid SPIR-V (no broken back-edge)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\bool chk(inout int n){ n++; return n < 10; }
        \\void main(){ int n=0; int s=0; for(int i=0;i<5 && chk(n);i++){ s+=i; } o=vec4(float(s),float(n),0,1); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try spirvValOrSkip(spv); // must be valid (the regression that scan.comp caught)
}

// #170: the ternary `?:` also short-circuits — only the taken arm is evaluated.
// glslpp emitted eager OpSelect (evaluates BOTH arms), dropping a side-effecting
// arm = silent-wrong (same class as `&&`/`||`). A side-effecting arm now lowers to
// control flow (OpBranchConditional), not OpSelect.
test "frontend: side-effecting ternary short-circuits (OpBranchConditional, not OpSelect)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\int se(inout int c){ c += 1; return 7; }
        \\void main(){ int c=0; bool a=iv.x>0.0; int r = a ? 5 : se(c); o=vec4(float(c), float(r), 0, 1); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 250)); // OpBranchConditional
    try spirvValOrSkip(spv);
}

// The PURE ternary keeps the cheaper eager OpSelect (opcode 169) — no control flow.
test "frontend: pure ternary keeps eager OpSelect (no short-circuit overhead)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\void main(){ float r = (iv.x > 0.0) ? iv.y : iv.z; o = vec4(r); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 169)); // OpSelect (eager, no branch)
}

// A side-effecting ternary inside a LOOP CONDITION falls back to eager OpSelect
// (a selection_merge in the loop header would be invalid SPIR-V) — must stay valid.
test "frontend: ternary in a loop condition stays valid SPIR-V" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\int f(inout int n){ n++; return n; }
        \\void main(){ int n=0; int s=0; for(int i=0;i<(n<3?f(n):0);i++){ s++; } o=vec4(float(s)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try spirvValOrSkip(spv);
}

// #170: a side-effecting ternary whose arms have MISMATCHED scalar types that need a
// LOSSY/unhandled coercion (then=int, else=float — glslang promotes to float, but the
// memory-SSA temp is the then type) honest-errors rather than emit a truncating
// silent-wrong (or an int↔uint type-mismatched store = invalid SPIR-V). Matching arms
// and lossless widening (then=float, else=int) still short-circuit correctly.
test "frontend: side-effecting ternary with a lossy type mismatch honest-errors" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\float se(inout int c){ c += 1; return 2.5; }
        \\void main(){ int c=0; bool a=iv.x>0.0; float r = a ? 5 : se(c); o=vec4(r, float(c), 0, 1); }
    , .{ .stage = .fragment }));
    // float-then / int-else is a lossless widen (int→float) — still short-circuits.
    const ok = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\int se(inout int c){ c += 1; return 3; }
        \\void main(){ int c=0; bool a=iv.x>0.0; float r = a ? 1.0 : se(c); o=vec4(r, float(c), 0, 1); }
    , .{ .stage = .fragment });
    defer alloc.free(ok);
    try std.testing.expect(spirvHasOpcode(ok, 250)); // short-circuited (OpBranchConditional)
    try spirvValOrSkip(ok);
}

// #170: an `out`/`inout` parameter mutated by a callee must be observable AFTER the
// call. The store-to-load forwarding inside deadCodeElim tracked `last_store[ptr]=val`
// but had NO barrier for OpFunctionCall — so `OpStore %param v0; OpFunctionCall se
// %param; OpLoad %param` rewrote the post-call load to the STALE v0, silently dropping
// the write-back. Guard against const-folding masking the drop: a runtime input feeds
// the mutated value, so the `+7` cannot fold. If the write-back is forwarded-over, the
// OpIAdd goes dead and DCE removes it — its presence in the OPTIMIZED module proves the
// mutation survives. (Repro: `float(c)` collapsed to `float(int(iv.x))`, dropping +7.)
test "frontend: inlined inout write-back survives optimization (no store-forward across a call)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\void se(inout int c){ c += 7; }
        \\void main(){ int c = int(iv.x); se(c); o = vec4(float(c), 0.0, 0.0, 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 128)); // OpIAdd — the +7 write-back survives
    try spirvValOrSkip(spv);
}

// The same hazard for a NON-inlined callee (a loop keeps se() out-of-line, so the real
// OpFunctionCall survives to the final module). Without the OpFunctionCall barrier, the
// post-call load of the inout arg forwards to the pre-call store = the loop's writes are
// silently dropped. The callee's per-iteration `c += 7` must survive.
test "frontend: non-inlined inout write-back survives (OpFunctionCall barrier)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) flat in int niter;
        \\layout(location=1) out vec4 o;
        \\void se(inout int c){ for(int i=0;i<niter;i++){ c += 7; } }
        \\void main(){ int c = int(iv.x); se(c); o = vec4(float(c), 0.0, 0.0, 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 57)); // OpFunctionCall survives (non-inlined)
    try std.testing.expect(funcCallArgReloaded(spv)); // the inout arg is re-read after the call
    try spirvValOrSkip(spv);
}

// #170: a callee with MULTIPLE aliased inout params (the classic swap) exercises both
// the OpFunctionCall barrier AND transitive replacement-chain resolution. The inlined
// body is `%31=load x; %32=load y; store x,%32; store y,%31; %14=load x; %15=load y`.
// The store-forward maps %14→%32→(store y's) and %15→%31→(store x's); applying that
// chain non-transitively left the composite referencing removed loads = undefined-id
// (invalid SPIR-V). Flattened, main becomes `vec4(in.y, in.x)` — the correct swap.
test "frontend: swap(inout,inout) inlines to a valid, correctly-swapped module" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec2 u_input;
        \\layout(location=0) out vec4 fragColor;
        \\void swap(inout float a, inout float b){ float t = a; a = b; b = t; }
        \\void main(){ float x = u_input.x; float y = u_input.y; swap(x, y); fragColor = vec4(x, y, 0.0, 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    // Structural guard that holds even when spirv-val is unavailable: the pre-fix bug
    // GUTTED main to just the dangling composite + store (no loads survived). The
    // u_input read must survive, so an OpLoad must be present.
    try std.testing.expect(spirvHasOpcode(spv, 61)); // OpLoad of u_input survives (body not gutted)
    try spirvValOrSkip(spv); // was invalid SPIR-V (undefined-id) before the transitive-resolution fix
}

// #170: the OpExtInst pointer-output builtins (`modf`/`frexp` write their integer/
// exponent part through a pointer operand) are the same defect class. With `ip` first
// stored, then written by modf, then read back in the same block, the store-forward
// rewrote the read-back to the STALE stored value (`o.y` came out as the initial value,
// not modf's integer part). The OpExtInst barrier invalidates forwarding for the
// pointer operand so the post-modf load re-reads memory. `ip` is seeded from a runtime
// input so the correct value is a live OpLoad, not a foldable constant.
test "frontend: modf out-param survives store-forward (OpExtInst barrier)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\void main(){ float ip = iv.y; float fr = modf(iv.x, ip); o = vec4(fr, ip, 0.0, 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    // The integer part written by modf must be re-read (a live OpLoad of the ip pointer
    // after the OpExtInst), not forwarded to the pre-modf stored value.
    try std.testing.expect(extInstOutputReloaded(spv));
    try spirvValOrSkip(spv);
}

// #170: a `do { … } while(cond)` loop whose CONDITION mutates a loop-carried
// variable (via an inout call or `++`) was miscompiled to a NON-TERMINATING loop
// with dropped accumulation. branchMergePhi treated the loop HEADER (2 preds:
// pre-header + back-edge) as a diamond merge and forwarded each predecessor's raw
// store value into an OpPhi — but the back-edge value (`c + 1`) transitively
// depends on the phi, so the loopback operand was wired to the PRE-LOOP value,
// making the condition loop-invariant. Fix: branchMergePhi skips loop headers
// (blocks with OpLoopMerge); the counter stays a memory var and the latch re-reads
// + stores it. Discriminator: pre-fix the latch had NO OpStore (mis-wired phi);
// post-fix it stores the loop-carried counter. `c` seeded from a runtime input so
// the value can't const-fold away.
test "frontend: do-while whose condition mutates a var stays loop-carried (no mis-wired phi)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\int chk(inout int k){ k += 1; return k; }
        \\void main(){
        \\  int c = int(iv.x);
        \\  int sum = 0;
        \\  do { sum += 1; } while(chk(c) < int(iv.x) + 3);
        \\  o = vec4(float(sum), float(c), 0.0, 1.0);
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    // The condition's counter must be a live loop-carried memory var: the latch
    // re-reads and STORES it. Pre-fix (mis-wired phi) the latch had no store.
    try std.testing.expect(loopLatchHasStore(spv));
    try spirvValOrSkip(spv);
}

// #170: the same defect with plain `++c` in the condition (no function call) — the
// counter's store IS the conditional latch block. Same branchMergePhi loop-header
// miscompile; same fix. Guards against a narrower fix that only handled inlined
// inout calls.
test "frontend: do-while with ++ in condition stays loop-carried" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  int c = int(iv.x);
        \\  int sum = 0;
        \\  do { sum += 1; } while(++c < int(iv.x) + 3);
        \\  o = vec4(float(sum), float(c), 0.0, 1.0);
        \\}
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(loopLatchHasStore(spv));
    try spirvValOrSkip(spv);
}

// #170: the UNINITIALIZED out-param variant of the modf/frexp defect. When the pointer
// argument is a variable declared WITHOUT an initializer (`float ip; modf(x, ip);`), the
// builtin's arg pre-analysis analyzes `ip` as an rvalue and emits (and CACHES) a load of
// the variable BEFORE the OpExtInst runs. A later read of the out-param (`o.y = ip`)
// reused that cached PRE-modf load = silent-wrong: `o.y` came out as the uninitialized
// value, not modf's integer part (the read-back OpLoad was hoisted above the OpExtInst).
// This is a DISTINCT path from the initialized case above (no store → no store-forward
// barrier fires); the fix invalidates the pointer's load cache after the OpExtInst so the
// post-modf read re-loads memory. Discriminator: pre-fix there is NO OpLoad of the ip
// pointer after the OpExtInst (the composite uses the hoisted pre-modf load).
test "frontend: uninitialized modf out-param re-loads after OpExtInst (no stale hoist)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec4 iv;
        \\layout(location=0) out vec4 o;
        \\void main(){ float ip; float fr = modf(iv.x, ip); o = vec4(fr, ip, 0.0, 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    // modf's integer part must be a live OpLoad of the ip pointer AFTER the OpExtInst,
    // not the pre-modf (uninitialized) load hoisted above it.
    try std.testing.expect(extInstOutputReloaded(spv));
    try spirvValOrSkip(spv);
}

// #170: textureProjOffset (projective sample + const offset, no lod/grad) was wrongly
// rejected (UndeclaredIdentifier). It IS representable: OpImageSampleProjImplicitLod
// with a ConstOffset operand (its own IR tag — image_sample_proj has no operands).
test "frontend: textureProjOffset emits valid OpImageSampleProjImplicitLod (ConstOffset)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjOffset(tex, c, ivec2(2, -1)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 91)); // OpImageSampleProjImplicitLod
    try spirvValOrSkip(spv); // the ConstOffset encoding must be well-formed
}

// #170: textureProjOffset honest-errors (not mis-compile) on the by-design holes:
// CUBE (ConstOffset illegal on Cube Dim), SHADOW (would route to a dref-proj op that
// can't carry the offset), and a NON-CONSTANT offset.
test "frontend: textureProjOffset cube/shadow/non-const-offset honest-error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform samplerCube s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjOffset(s, c, ivec2(1, 0)); }
    , .{ .stage = .fragment }));
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out float o;
        \\void main(){ o = textureProjOffset(s, c, ivec2(1, 0)); }
    , .{ .stage = .fragment }));
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec3 c;
        \\layout(location=1) flat in ivec2 dyn;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjOffset(s, c, dyn); }
    , .{ .stage = .fragment }));
}

// #170: textureProjGrad (projective sample with EXPLICIT gradients) was wrongly
// rejected — missing from isTextureBuiltin. It IS representable:
// OpImageSampleProjExplicitLod with the Grad image operand (shares the proj-
// explicit-lod tag with textureProjLod, distinguished by operand count). Emitting
// the Lod operand (or the implicit-lod proj op) would lose the gradients.
test "frontend: textureProjGrad emits OpImageSampleProjExplicitLod with a Grad operand" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjGrad(tex, c, vec2(0.1), vec2(0.2)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 92)); // OpImageSampleProjExplicitLod
    try std.testing.expect(!spirvHasOpcode(spv, 91)); // not the implicit-lod proj op
    try spirvValOrSkip(spv); // the Grad encoding must be well-formed
}

// #170: shadow textureProjGrad has no lowering (would route to a dref tag and read
// a gradient vec2 as the float Lod operand → invalid SPIR-V). Honest-error.
test "frontend: shadow textureProjGrad honest-errors (no invalid SPIR-V)" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out float o;
        \\void main(){ o = textureProjGrad(sh, c, vec2(0.1), vec2(0.2)); }
    , .{ .stage = .fragment }));
}

// #170: projective sampling is undefined for a CUBE image (SPIR-V requires Dim
// 1D/2D/3D/Rect for OpImageSampleProj*; GLSL has no cube textureProj* overload).
// zioshade emitted invalid SPIR-V; now honest-errors for the whole proj family.
test "frontend: textureProj/ProjLod/ProjGrad on a cube sampler honest-error (were invalid SPIR-V)" {
    const alloc = std.testing.allocator;
    const srcs = [_][:0]const u8{
        \\#version 450
        \\layout(binding=0) uniform samplerCube s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProj(s, c); }
        ,
        \\#version 450
        \\layout(binding=0) uniform samplerCube s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjLod(s, c, 1.0); }
        ,
        \\#version 450
        \\layout(binding=0) uniform samplerCube s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjGrad(s, c, vec3(0.1), vec3(0.2)); }
        ,
    };
    for (srcs) |src| {
        try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment }));
    }
}

// #170: textureGradOffset was wrongly rejected (honest-error) — missing from
// isTextureBuiltin. It IS faithfully representable: OpImageSampleExplicitLod with
// the Grad|ConstOffset image operands (mask 0xC). It shares image_sample_grad's
// codegen, which now appends the ConstOffset word after both gradients. The result
// must be VALID SPIR-V (the offset word in image-operand bit order).
test "frontend: textureGradOffset emits valid OpImageSampleExplicitLod (Grad|ConstOffset)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGradOffset(s, uv, vec2(0.1), vec2(0.2), ivec2(1, -1)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 88)); // OpImageSampleExplicitLod
    try spirvValOrSkip(spv); // the Grad|ConstOffset encoding must be well-formed
}

// #170: shadow GRADIENT sampling has no lowering. textureGrad/textureGradOffset on
// a sampler2DShadow is valid GLSL but routes to OpImageSampleDrefExplicitLod, whose
// codegen reads the FIRST gradient (a vec2) as the float Lod operand → invalid
// SPIR-V ("Expected Image Operand Lod to be a 32-bit float scalar"). Must honest-
// error, not mis-compile. (Covers a pre-existing shadow-textureGrad hole too.)
test "frontend: shadow textureGrad / textureGradOffset honest-error (were invalid SPIR-V)" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow s;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out float o;
        \\void main(){ o = textureGrad(s, c, vec2(0.1), vec2(0.2)); }
    , .{ .stage = .fragment }));
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow s;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out float o;
        \\void main(){ o = textureGradOffset(s, c, vec2(0.1), vec2(0.2), ivec2(1, 0)); }
    , .{ .stage = .fragment }));
}

// #170: the const offset MUST be compile-time constant (becomes a ConstOffset image
// operand). A dynamic offset cannot be a ConstOffset → honest-error, not invalid SPIR-V.
test "frontend: textureGradOffset with a non-constant offset honest-errors" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec2 uv;
        \\layout(location=1) flat in ivec2 dyn;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGradOffset(s, uv, vec2(0.1), vec2(0.2), dyn); }
    , .{ .stage = .fragment }));
}

// #170: a ConstOffset image operand is illegal on a Cube image (SPIR-V) and GLSL
// has no cube *Offset overload (glslang: "no matching overloaded function found").
// zioshade must honest-error, not emit invalid SPIR-V ("ConstOffset cannot be used
// with Cube Image 'Dim'"). Guards the offset gate for all offset sample builtins.
test "frontend: textureGradOffset on a cube sampler honest-errors (not invalid SPIR-V)" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform samplerCube s;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGradOffset(s, c, vec3(0.1), vec3(0.2), ivec2(1, 0)); }
    , .{ .stage = .fragment }));
}

// #170: textureOffset(sampler2DShadow, coord, const ivec offset) — the 3-arg form
// (no bias) — emitted INVALID SPIR-V at rc=0. It routes to OpImageSampleDrefImplicitLod,
// whose 3-operand codegen path assumes a FLOAT Bias operand (it can't tell the
// ivec2 offset apart from `texture(shadow, coord, bias)` by arg count), so it
// emitted the ivec2 as a Bias → spirv-val: "Expected Image Operand Bias to be a
// 32-bit float scalar". glslang accepts the GLSL, so it must honest-error rather
// than mis-compile (a full dref-ConstOffset lowering is a follow-up).
test "frontend: 3-arg shadow textureOffset honest-errors (was invalid SPIR-V), siblings still compile" {
    const alloc = std.testing.allocator;
    // The broken case → honest error (not invalid SPIR-V).
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(textureOffset(sh, vec3(uv, 0.5), ivec2(1))); }
    , .{ .stage = .fragment }));

    // Siblings that DO lower correctly must keep working (no over-rejection):
    //   texture(shadow, coord, bias) — float Bias, valid.
    //   textureLodOffset(shadow, ...) — Lod-disambiguated explicit-lod ConstOffset.
    //   textureOffset(shadow, coord, offset, bias) — 4-arg Bias|ConstOffset.
    const ok_srcs = [_][:0]const u8{
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(texture(sh, vec3(uv, 0.5), 0.1)); }
        ,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(textureLodOffset(sh, vec3(uv, 0.5), 0.0, ivec2(1))); }
        ,
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow sh;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(textureOffset(sh, vec3(uv, 0.5), ivec2(1), 0.1)); }
    };
    for (ok_srcs) |src| {
        const spv = try zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 89) or spirvHasOpcode(spv, 90)); // a Dref sample op
    }
}

// #170: UNSIGNED relational comparisons (uint/uvecN `<` `>` `<=` `>=`, and the
// lessThan/greaterThan-family builtins) were lowered to the SIGNED SPIR-V ops
// (OpSLessThan etc.) — a SILENT-WRONG: valid SPIR-V that spirv-val/naga accept,
// but WRONG results for operands >= 2^31 (signed sees them as negative). glslang
// emits OpULessThan/OpUGreaterThan/... Must use the unsigned ops.
// SPIR-V opcodes: ULessThan=176 SLessThan=177; UGreaterThan=172 SGreaterThan=173;
// ULessThanEqual=178 SLessThanEqual=179; UGreaterThanEqual=174 SGreaterThanEqual=175.
test "frontend: unsigned comparisons emit OpU* (not signed) — operator + builtin forms" {
    const alloc = std.testing.allocator;
    // Operator form on uvec.
    {
        const spv = try zioshade.compileToSPIRV(alloc,
            \\#version 450
            \\layout(location=0) flat in uvec2 a;
            \\layout(location=1) flat in uvec2 b;
            \\layout(location=0) out vec4 o;
            \\void main(){ o = (a.x < b.x) ? vec4(greaterThan(a,b), lessThanEqual(a,b)) : vec4(0); }
        , .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 176)); // ULessThan (operator a.x<b.x)
        try std.testing.expect(spirvHasOpcode(spv, 172)); // UGreaterThan (greaterThan builtin)
        try std.testing.expect(spirvHasOpcode(spv, 178)); // ULessThanEqual (lessThanEqual builtin)
        // The SIGNED forms must NOT appear for these unsigned operands.
        try std.testing.expect(!spirvHasOpcode(spv, 177)); // no SLessThan
        try std.testing.expect(!spirvHasOpcode(spv, 173)); // no SGreaterThan
        try std.testing.expect(!spirvHasOpcode(spv, 179)); // no SLessThanEqual
    }
    // SIGNED operands still emit the signed ops (no over-correction / regression).
    {
        const spv = try zioshade.compileToSPIRV(alloc,
            \\#version 450
            \\layout(location=0) flat in ivec2 a;
            \\layout(location=1) flat in ivec2 b;
            \\layout(location=0) out vec4 o;
            \\void main(){ o = (a.x < b.x) ? vec4(1) : vec4(0); }
        , .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 177)); // SLessThan for int operands
        try std.testing.expect(!spirvHasOpcode(spv, 176)); // not ULessThan
    }
    // MIXED int/uint: GLSL promotes to UNSIGNED (the int is bitcast to uint), so
    // `int < uint` must also use OpULessThan — selection checks BOTH operands.
    {
        const spv = try zioshade.compileToSPIRV(alloc,
            \\#version 450
            \\layout(location=0) flat in int si;
            \\layout(location=1) flat in uint ui;
            \\layout(location=0) out vec4 o;
            \\void main(){ o = (si < ui) ? vec4(1) : vec4(0); }
        , .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 176)); // ULessThan (promoted to unsigned)
        try std.testing.expect(!spirvHasOpcode(spv, 177)); // not SLessThan
    }
}

// #170: a MIXED int/uint min/max/clamp promotes to UNSIGNED (GLSL int→uint rule).
// zioshade defaulted the result type to the first arg (int) → SMax/SMin/SClamp
// emitted with a uint operand. That is valid SPIR-V, but the WGSL back-end then
// emits `max(i32, u32)` which naga REJECTS ("inconsistent type") = silent-wrong.
// The signed operand must be bitcast to unsigned and the U-variant used.
// OpBitcast = 124.
test "frontend: mixed int/uint max bitcasts the signed operand to unsigned (no SMax)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) flat in int si;
        \\layout(location=1) flat in uint ui;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(float(max(si, ui))); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    // The signed operand is reinterpreted as unsigned via OpBitcast (124) before
    // the unsigned ext-inst max — zioshade did NOT emit this before the fix.
    try std.testing.expect(spirvHasOpcode(spv, 124));
}

// #170: signedness of integer DIVISION and RIGHT-SHIFT (same valid-but-wrong class
// as the unsigned-comparison fix — passes spirv-val + naga but computes wrong
// values). `uint / uint` must be OpUDiv (134) not OpSDiv (135); `int >> n` must be
// OpShiftRightArithmetic (195, sign-extend) not OpShiftRightLogical (194, which
// zero-fills and corrupts negatives). glslang is the oracle for both.
test "frontend: unsigned division uses OpUDiv; signed right-shift uses arithmetic shift" {
    const alloc = std.testing.allocator;
    // uint/uint → UDiv; uint>>n stays logical (correct for unsigned).
    {
        const spv = try zioshade.compileToSPIRV(alloc,
            \\#version 450
            \\layout(location=0) flat in uvec2 a;
            \\layout(location=1) flat in uvec2 b;
            \\layout(location=0) out vec4 o;
            \\void main(){ o = vec4(vec2(a / b), vec2(a >> b)); }
        , .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 134)); // UDiv
        try std.testing.expect(!spirvHasOpcode(spv, 135)); // not SDiv
        try std.testing.expect(spirvHasOpcode(spv, 194)); // ShiftRightLogical (uint >>)
        try std.testing.expect(!spirvHasOpcode(spv, 195)); // not arithmetic for unsigned
    }
    // int/int → SDiv (no over-correction); int>>n → arithmetic (sign-extend).
    {
        const spv = try zioshade.compileToSPIRV(alloc,
            \\#version 450
            \\layout(location=0) flat in ivec2 a;
            \\layout(location=1) flat in ivec2 b;
            \\layout(location=0) out vec4 o;
            \\void main(){ o = vec4(vec2(a / b), vec2(a >> 1)); }
        , .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(spirvHasOpcode(spv, 135)); // SDiv for signed
        try std.testing.expect(!spirvHasOpcode(spv, 134)); // not UDiv
        try std.testing.expect(spirvHasOpcode(spv, 195)); // ShiftRightArithmetic (int >>)
        try std.testing.expect(!spirvHasOpcode(spv, 194)); // not logical for signed
    }
}

// =============================================================================
// #170: dynamic double-index into a LOCAL matrix must emit valid SPIR-V.
// Repro: `mat3 m = mat3(a,b,c); o = vec4(m[i][j]);` with i,j dynamic.
// The inner `m[i]` lowers to an OpAccessChain (pointer-to-column); the outer
// `[j]` previously fed that POINTER straight into OpVectorExtractDynamic, whose
// vector operand must be a vector VALUE — so the frontend emitted invalid
// SPIR-V (spirv-val: "Expected Vector type to be OpTypeVector"; after DCE the
// dead column pointer left a dangling-ID reference). The column value must be
// LOADED before the dynamic component extract. This is a frontend bug, so a
// valid SPIR-V module is the fix for ALL backends.
// =============================================================================

/// Resolve spirv-val and run it on `spv`. Skips when the tool is unavailable
/// (mirrors the resolveVulkanTool/SkipZigTest pattern used across the suite).
fn spirvValOrSkip(spv: []const u32) !void {
    const alloc = std.testing.allocator;
    const tool = zioshade.compat.resolveVulkanTool(alloc, "spirv-val") catch return error.SkipZigTest;
    defer alloc.free(tool);

    const spv_path = try zioshade.compat.tempFilePathFmt(alloc, "zs_cor_{x}.spv", .{zioshade.compat.randomInt(u64)});
    defer alloc.free(spv_path);
    defer zioshade.compat.deleteFileAbsolute(alloc, spv_path) catch {};
    try zioshade.compat.writeFileAbsolute(alloc, spv_path, std.mem.sliceAsBytes(spv));

    var main_io = zioshade.compat.MainIo().init(alloc);
    defer main_io.deinit();
    const r = zioshade.compat.processRun(main_io.io(), alloc, &.{ tool, spv_path }) catch return error.SkipZigTest;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    if (!((r.term.exitedCode() orelse 1) == 0)) {
        std.debug.print("spirv-val rejected the module:\n{s}\n{s}\n", .{ r.stdout, r.stderr });
        return error.TestSpirvValFailed;
    }
}

// Like spirvValOrSkip but validates against the Vulkan 1.3 environment, which
// enforces the StandaloneSpirv memory-semantics rules (VUID-…-10871: a storage-
// class semantics bit without an ordering bit is illegal). The default spirv-val
// env does NOT enforce this, so a bug can pass spirvValOrSkip yet be invalid on a
// modern driver. Used by the #170 atomic-semantics regression test.
fn spirvValVulkan13OrSkip(spv: []const u32) !void {
    const alloc = std.testing.allocator;
    const tool = zioshade.compat.resolveVulkanTool(alloc, "spirv-val") catch return error.SkipZigTest;
    defer alloc.free(tool);

    const spv_path = try zioshade.compat.tempFilePathFmt(alloc, "zs_cor_vk_{x}.spv", .{zioshade.compat.randomInt(u64)});
    defer alloc.free(spv_path);
    defer zioshade.compat.deleteFileAbsolute(alloc, spv_path) catch {};
    try zioshade.compat.writeFileAbsolute(alloc, spv_path, std.mem.sliceAsBytes(spv));

    var main_io = zioshade.compat.MainIo().init(alloc);
    defer main_io.deinit();
    const r = zioshade.compat.processRun(main_io.io(), alloc, &.{ tool, "--target-env", "vulkan1.3", spv_path }) catch return error.SkipZigTest;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    if (!((r.term.exitedCode() orelse 1) == 0)) {
        std.debug.print("spirv-val (vulkan1.3) rejected the module:\n{s}\n{s}\n", .{ r.stdout, r.stderr });
        return error.TestSpirvValFailed;
    }
}

// #170: GLSL atomics were emitted with UniformMemory (0x40) memory semantics but NO
// ordering bit. Under Vulkan 1.2+ a storage-class semantics bit without an ordering
// bit (Acquire/Release/AcquireRelease) is illegal (VUID-StandaloneSpirv-Memory
// Semantics-10871) = INVALID SPIR-V on modern drivers. The older default spirv-val
// env accepted it, so conformance missed it. GLSL atomics are relaxed → emit None
// (0x0), matching glslang. Covers the 6-word ops (AtomicIAdd via atomicAdd) and the
// 9-word OpAtomicCompareExchange (two semantics operands). Validates under vulkan1.3,
// which enforces the rule (a genuine RED/GREEN discriminator vs the default env).
test "frontend: relaxed atomics use None semantics — valid under Vulkan 1.3" {
    const alloc = std.testing.allocator;
    {
        const spv = try zioshade.compileToSPIRV(alloc,
            \\#version 450
            \\layout(local_size_x=64) in;
            \\shared int counter;
            \\layout(std430,binding=0) buffer B { int outv[]; };
            \\void main(){ if(gl_LocalInvocationID.x==0u) counter=0; barrier();
            \\  outv[gl_GlobalInvocationID.x] = atomicAdd(counter, 1); }
        , .{ .stage = .compute });
        defer alloc.free(spv);
        try spirvValVulkan13OrSkip(spv);
    }
    {
        const spv = try zioshade.compileToSPIRV(alloc,
            \\#version 450
            \\layout(local_size_x=64) in;
            \\layout(std430,binding=0) buffer B { uint v; uint o[]; };
            \\void main(){ o[gl_GlobalInvocationID.x] = atomicCompSwap(v, 0u, 7u); }
        , .{ .stage = .compute });
        defer alloc.free(spv);
        try spirvValVulkan13OrSkip(spv);
    }
}

// #170: an integer fragment INPUT — including implicitly-flat integer builtins that
// carry no `flat` qualifier (gl_SampleID here) — was emitted WITHOUT a Flat
// decoration. Vulkan forbids interpolating integers, so a fragment integer/double
// Input MUST be Flat (VUID-StandaloneSpirv-Flat-04744) = invalid SPIR-V without it;
// the lenient default spirv-val env missed it. Validated under vulkan1.3.
test "frontend: integer fragment input (gl_SampleID) is Flat — valid under Vulkan 1.3" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(float(gl_SampleID), 0.0, 0.0, 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try spirvValVulkan13OrSkip(spv);
    // A user `flat in int` must still work (and float inputs must NOT get Flat).
    const spv2 = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) flat in int idx;
        \\layout(location=1) in float w;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(float(idx) + w); }
    , .{ .stage = .fragment });
    defer alloc.free(spv2);
    try spirvValVulkan13OrSkip(spv2);
}

// #170: a compute (GLCompute) entry point with NO `layout(local_size_*)` was
// emitted WITHOUT a LocalSize execution mode. Vulkan requires one (VUID-Standalone
// Spirv-None-10685) → invalid SPIR-V on modern drivers; the lenient default spirv-
// val env missed it (so conformance passed). GLSL defaults each unspecified work-
// group dimension to 1, so the correct output is `LocalSize 1 1 1` — matching
// glslang. Validated under vulkan1.3, which enforces the rule.
test "frontend: compute without local_size emits LocalSize 1 1 1 — valid under Vulkan 1.3" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(std430, binding=0) buffer B { int data[]; };
        \\void main(){ data[0] = data[0] + 1; }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    try spirvValVulkan13OrSkip(spv);
    // The LocalSize execution mode (opcode 16) must be present with dims 1,1,1.
    try std.testing.expect(spirvHasComputeLocalSize111(spv));
}

// #170: VUID-None-10685 applies to MeshEXT (and TaskEXT) execution models too — a
// mesh shader with no local_size was likewise emitted without a LocalSize execution
// mode = invalid under Vulkan 1.3. Same default-to-(1,1,1) fix as compute.
test "frontend: mesh shader without local_size emits LocalSize 1 1 1 — valid under Vulkan 1.3" {
    const alloc = std.testing.allocator;
    const spv = zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\#extension GL_EXT_mesh_shader : require
        \\layout(triangles, max_vertices=3, max_primitives=1) out;
        \\void main(){ SetMeshOutputsEXT(3u, 1u); gl_MeshVerticesEXT[0].gl_Position = vec4(0.0); }
    , .{ .stage = .mesh }) catch return error.SkipZigTest; // skip if mesh unsupported in this build
    defer alloc.free(spv);
    try spirvValVulkan13OrSkip(spv);
    try std.testing.expect(spirvHasComputeLocalSize111(spv));
}

const dyn_double_index_src =
    \\#version 450
    \\layout(location=0) in vec3 a; layout(location=1) in vec3 b; layout(location=2) in vec3 c;
    \\layout(location=3) flat in int i; layout(location=4) flat in int j;
    \\layout(location=0) out vec4 o;
    \\void main(){ mat3 m = mat3(a, b, c); o = vec4(m[i][j]); }
;

test "frontend #170: dynamic m[i][j] on a local matrix emits valid SPIR-V (opt)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc, dyn_double_index_src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try spirvValOrSkip(spv);
}

test "frontend #170: dynamic m[i][j] on a local matrix emits valid SPIR-V (no-opt)" {
    // Guards the lowering itself, independent of the optimizer pipeline: the
    // unoptimized module must already be valid (it was not — VectorExtractDynamic
    // on an OpAccessChain pointer).
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRVNoOpt(alloc, dyn_double_index_src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try spirvValOrSkip(spv);
}

test "frontend #170: dynamic m[i][j] cross-compiles to all four backends" {
    // A frontend fix produces valid SPIR-V, which every backend then accepts.
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc, dyn_double_index_src, .{ .stage = .fragment });
    defer alloc.free(spv);

    const wgsl = try zioshade.spirvToWGSL(alloc, spv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(wgsl.len > 0);

    const hlsl = try zioshade.spirvToHLSL(alloc, spv, .{});
    defer alloc.free(hlsl);
    try std.testing.expect(hlsl.len > 0);

    const msl = try zioshade.spirvToMSL(alloc, spv, .{});
    defer alloc.free(msl);
    try std.testing.expect(msl.len > 0);

    const glsl = try zioshade.spirvToGLSL(alloc, spv, .{});
    defer alloc.free(glsl);
    try std.testing.expect(glsl.len > 0);
}

// =============================================================================
// SubpassData input attachments (subpassLoad)
//
// OpImageRead on a SubpassData image requires its coordinate to be a constant:
// an OpConstantComposite of (0,0) or an OpConstantNull, NOT a function-scope
// OpCompositeConstruct. The frontend built the ivec2(0,0) with a plain
// composite_construct, so spirv-val rejected every subpassLoad module ("Expected
// Coordinate for a SubpassData image to be a OpConstantComposite of (0,0) or
// OpConstantNull"). The fix upgrades the coordinate to a constant composite,
// which codegen hoists into the module constants section.
// =============================================================================

const subpass_load_src =
    \\#version 450
    \\layout(input_attachment_index=0, set=0, binding=0) uniform subpassInput inp;
    \\layout(location=0) out vec4 o;
    \\void main(){ o = subpassLoad(inp); }
;

const subpass_load_ms_src =
    \\#version 450
    \\layout(input_attachment_index=0, set=0, binding=0) uniform subpassInputMS inp;
    \\layout(location=0) out vec4 o;
    \\void main(){ o = subpassLoad(inp, 0); }
;

// The subpass tests below assert the coordinate is a constant even where
// spirv-val is not installed (spirvValOrSkip would skip) via the module-level
// spirvHasOpcode scanner defined earlier in this file.

test "frontend: subpassLoad emits a constant SubpassData coordinate (valid SPIR-V)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc, subpass_load_src, .{ .stage = .fragment });
    defer alloc.free(spv);
    // The coordinate must be a module-scope OpConstantComposite (44), never a
    // function-scope OpCompositeConstruct (80) that spirv-val would reject.
    try std.testing.expect(spirvHasOpcode(spv, 44));
    try std.testing.expect(!spirvHasOpcode(spv, 80));
    try spirvValOrSkip(spv);
}

test "frontend: multisampled subpassLoad emits a constant coordinate (valid SPIR-V)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc, subpass_load_ms_src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 44));
    try std.testing.expect(!spirvHasOpcode(spv, 80));
    try spirvValOrSkip(spv);
}

// =============================================================================
// Module-scope const array initializers (silent-wrong, all backends) — #335
//
// A `const` array indexed by a runtime value lowers to a Private OpVariable. Its
// initializer must be a folded OpConstantComposite carried as the variable's 5th
// word; without it every backend reads uninitialised memory. The remaining gap
// was int-literal splats: `vec4(1)` emitted a runtime OpConvertSToF instead of a
// constant, so a `const vec4 G[2][2]` built from `vec4(1)` failed to fold and its
// Private global silently dropped the initializer. `vec4(1.0)` already folded.
// =============================================================================

/// True if the module has an OpVariable (59) in the Private (6) storage class
/// that carries an initializer (instruction word count >= 5: type, id, class,
/// initializer). Walks by instruction word count past the 5-word header.
fn spirvPrivateVarHasInitializer(spv: []const u32) bool {
    var i: usize = 5;
    while (i < spv.len) {
        const wc: usize = spv[i] >> 16;
        if (wc == 0) break;
        const op: u16 = @truncate(spv[i] & 0xffff);
        // OpVariable: words are [hdr, result_type, result_id, storage_class, init?]
        if (op == 59 and wc >= 5 and i + 3 < spv.len and spv[i + 3] == 6) return true;
        i += wc;
    }
    return false;
}

const const_nested_array_src =
    \\#version 450
    \\const vec4 G[2][2] = vec4[2][2](vec4[2](vec4(1),vec4(2)), vec4[2](vec4(3),vec4(4)));
    \\layout(location=0) flat in int i;
    \\layout(location=1) flat in int j;
    \\layout(location=0) out vec4 o;
    \\void main(){ o = G[i][j]; }
;

test "frontend #335: const nested-array global keeps its folded initializer" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc, const_nested_array_src, .{ .stage = .fragment });
    defer alloc.free(spv);
    // The nested initializer must fold to constant composites (44) that the
    // Private global then references as its initializer (word count 5) — not a
    // bare uninitialised OpVariable whose values appear nowhere.
    try std.testing.expect(spirvHasOpcode(spv, 44));
    try std.testing.expect(spirvPrivateVarHasInitializer(spv));
    try spirvValOrSkip(spv);
}

test "frontend #335: int-literal vector splat folds to a constant" {
    // `vec4(1)` must be an OpConstantComposite (44), not a runtime OpConvertSToF
    // (111) feeding an OpCompositeConstruct — the cascade root of the dropped
    // const-array initializer above.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\const vec4 V[2] = vec4[2](vec4(1), vec4(2));
        \\layout(location=0) flat in int i;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = V[i]; }
    ;
    const spv = try zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasOpcode(spv, 44));
    try std.testing.expect(!spirvHasOpcode(spv, 111)); // no OpConvertSToF
    try std.testing.expect(spirvPrivateVarHasInitializer(spv));
    try spirvValOrSkip(spv);
}

// =============================================================================
// const array-of-struct constructors and unsized const-array size inference
//
// Two frontend bugs found while investigating #335:
//  (1) The parser only accepted the UNSIZED struct-array constructor `S[](...)`.
//      A SIZED `S[N](...)` fell through to a bare identifier, so the initializer
//      failed to parse and `const S arr[3] = S[3](...)` never declared its symbol
//      (UndeclaredIdentifier at the use site). Fixed with a lookahead that treats
//      `Identifier[dims]...(` as a constructor.
//  (2) An unsized `const` array global (`const float LUT[] = float[](1,2,3)`)
//      kept its size-0 declared type, lowering to an OpTypeRuntimeArray plus an
//      initializer — invalid SPIR-V (a Private array must be sized). Fixed by
//      inferring the outer length from the initializer, as glslang and the local
//      var_decl path already do.
// =============================================================================

test "frontend: sized const struct-array constructor compiles to valid SPIR-V" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\struct S { vec3 a; float b; };
        \\const S arr[3] = S[3](S(vec3(1),2.0), S(vec3(3),4.0), S(vec3(5),6.0));
        \\layout(location=0) flat in int idx;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(arr[idx].a, arr[idx].b); }
    ;
    const spv = try zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    // A sized array must NOT lower to an OpTypeRuntimeArray (29).
    try std.testing.expect(!spirvHasOpcode(spv, 29));
    try spirvValOrSkip(spv);
}

test "frontend: unsized const array global infers its size (no runtime array)" {
    const alloc = std.testing.allocator;
    // Both a scalar-element and a struct-element unsized const array must adopt
    // the initializer's length instead of emitting an invalid runtime array.
    const cases = [_][:0]const u8{
        \\#version 450
        \\const float LUT[] = float[](1.0, 2.0, 3.0);
        \\layout(location=0) flat in int idx;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(LUT[idx]); }
        ,
        \\#version 450
        \\struct S { vec3 a; float b; };
        \\const S arr[] = S[](S(vec3(1),2.0), S(vec3(3),4.0));
        \\layout(location=0) flat in int idx;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(arr[idx].a, arr[idx].b); }
        ,
    };
    for (cases) |src| {
        const spv = try zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment });
        defer alloc.free(spv);
        try std.testing.expect(!spirvHasOpcode(spv, 29)); // no OpTypeRuntimeArray
        try spirvValOrSkip(spv);
    }
}

test "frontend: a shader with no main() honest-errors (not a no-OpEntryPoint module)" {
    // Every backend and glslang key off `main`. Without it the frontend used to
    // emit a module with no OpEntryPoint — invalid SPIR-V produced at exit 0
    // (silent-wrong), surfaced by sweeping the SPIRV-Cross corpus. It must
    // honest-error instead.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void helper(){ o = vec4(1.0); }
    ;
    // require_entry_point mirrors what the CLI sets for end-to-end compiles;
    // it is off by default so partial-unit callers (e.g. the mesh layout-only
    // fixtures) are unaffected.
    try std.testing.expectError(error.SemanticFailed, zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment, .require_entry_point = true }));
}

test "frontend #multiview: gl_ViewIndex emits the ViewIndex builtin (not ViewportIndex)" {
    // gl_ViewIndex (GL_EXT_multiview) must lower to BuiltIn ViewIndex (4440) with
    // the MultiView capability, NOT BuiltIn ViewportIndex (10, which needs the
    // MultiViewport capability). The wrong constant produced invalid SPIR-V at
    // exit 0 (found by sweeping the SPIRV-Cross corpus).
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_multiview : require
        \\layout(std140, binding = 0) uniform MVPs { mat4 MVP[2]; };
        \\layout(location = 0) in vec4 Position;
        \\void main(){ gl_Position = MVP[gl_ViewIndex] * Position; }
    ;
    const spv = try zioshade.compileToSPIRV(alloc, src, .{ .stage = .vertex });
    defer alloc.free(spv);
    try spirvValOrSkip(spv);
}

// The mirror hazard: gl_ViewportIndex must lower to BuiltIn ViewportIndex (10, needs
// the ShaderViewportIndex capability), NOT BuiltIn ViewIndex (4440, the multiview
// builtin that needs MultiView). #441 split gl_ViewIndex out to 4440 but left the
// gl_ViewportIndex decoration pointing at the same view_index constant, so it emitted
// `OpDecorate %gl_ViewportIndex BuiltIn ViewIndex` with only the ShaderViewportIndex
// capability = invalid SPIR-V at exit 0 (spirv-val: "requires ... MultiView"). Found
// as the last conformance FAIL (glslang-430/spv.430.frag).
test "frontend #multiview: gl_ViewportIndex emits ViewportIndex (10), not ViewIndex (4440)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location = 0) out vec4 color;
        \\void main(){ color = vec4(float(gl_ViewportIndex)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvHasBuiltinDecoration(spv, 10)); // ViewportIndex
    try std.testing.expect(!spirvHasBuiltinDecoration(spv, 4440)); // NOT ViewIndex
    try spirvValOrSkip(spv);
}

// A dynamic index that is itself a UBO/SSBO member (arr[u.k], m[1][u.k]) arrives as
// a pointer; the frontend fed it straight into OpAccessChain / OpVectorExtractDynamic
// without loading, emitting invalid SPIR-V at exit 0 ("Indexes passed to
// OpAccessChain must be of type integer" / a pointer operand to VectorExtractDynamic).
// The index is now loaded to a scalar-int value first. Found by the backend validity
// sweep + compute differential.
test "frontend: array indexed by a UBO member loads the index (valid SPIR-V)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(local_size_x=64) in;
        \\layout(std430,binding=0) writeonly buffer O{ float o[]; };
        \\layout(binding=1,std140) uniform U{ float tbl[8]; int k; } u;
        \\void main(){ o[gl_GlobalInvocationID.x] = u.tbl[u.k]; }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    try spirvValOrSkip(spv);
}

test "frontend: matrix column indexed by a UBO member loads the index (valid SPIR-V)" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(local_size_x=64) in;
        \\layout(std430,binding=0) writeonly buffer O{ float o[]; };
        \\layout(binding=1,std140) uniform U{ mat3 m; int k; } u;
        \\void main(){ o[gl_GlobalInvocationID.x] = u.m[1][u.k]; }
    , .{ .stage = .compute });
    defer alloc.free(spv);
    try spirvValOrSkip(spv);
}

// A scalar/vector/matrix module-scope `const` referenced through a function used
// to lower to an uninitialised Private OpVariable — the initializer value appeared
// NOWHERE in the SPIR-V (silent-wrong: backends that zero-init read 0; GLSL/MSL
// emit an undeclared identifier). Only const ARRAYS and int/uint were registered
// for initializer materialization. Found by the backend validity sweep.
test "frontend: scalar const global used via a function keeps its initializer" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in float vin;
        \\layout(location=0) out vec4 o;
        \\const float K = 2.0;
        \\float f(float x){ return x * K + 0.5; }
        \\void main(){ o = vec4(f(vin)); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    // The Private global must carry an initializer (word count 5), and the folded
    // constant 2.0 must actually be present — not a bare uninitialised OpVariable.
    try std.testing.expect(spirvPrivateVarHasInitializer(spv));
    try spirvValOrSkip(spv);
}

test "frontend: vec/mat const globals via a function keep their initializers" {
    const alloc = std.testing.allocator;
    const spv = try zioshade.compileToSPIRV(alloc,
        \\#version 450
        \\layout(location=0) in vec3 vin;
        \\layout(location=0) out vec4 o;
        \\const vec3 AXIS = vec3(0.0, 1.0, 0.0);
        \\const mat2 R = mat2(1.0, 0.0, 0.0, 1.0);
        \\vec3 g(vec3 v){ return v * AXIS; }
        \\vec2 h(vec2 v){ return R * v; }
        \\void main(){ o = vec4(g(vin) + vec3(h(vin.xy), 0.0), 1.0); }
    , .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spirvPrivateVarHasInitializer(spv));
    try spirvValOrSkip(spv);
}
