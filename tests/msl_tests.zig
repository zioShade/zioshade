// SPDX-License-Identifier: MIT OR Apache-2.0
//! MSL backend tests — end-to-end GLSL → SPIR-V → MSL pipeline.
//!
//! Tests use an observable side effect — `discard` or a write to a
//! `location` output — to keep the body alive through dead-code elimination.

const std = @import("std");
const zioshade = @import("zioshade");

const alloc = std.testing.allocator;

fn compileToMsl(source: [:0]const u8) ![]const u8 {
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try zioshade.spirvToMSL(alloc, spirv, .{});
}

fn compileToMslStage(source: [:0]const u8, stage: zioshade.Stage) ![]const u8 {
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = stage });
    defer alloc.free(spirv);
    return try zioshade.spirvToMSL(alloc, spirv, .{});
}

fn compileToMslStageVer(source: [:0]const u8, stage: zioshade.Stage, metal_version: u32) ![]const u8 {
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = stage });
    defer alloc.free(spirv);
    return try zioshade.spirvToMSL(alloc, spirv, .{ .metal_version = metal_version });
}

fn assertContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle)) |_| return;
    std.debug.print("Expected to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
    return error.TestExpectedFind;
}

fn assertNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return;
    std.debug.print("Expected NOT to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
    return error.TestUnexpectedFind;
}

/// Compile GLSL → SPIR-V with the *glslang* reference compiler (NOT zioshade's own
/// frontend). Needed for opcodes zioshade's frontend never emits — e.g. glslang
/// lowers every GLSL float `!=` to OpFUnordNotEqual, whereas the zioshade frontend
/// emits the ordered OpFOrdNotEqual. Skips the test if glslang is unavailable.
fn compileToSpirv(name: []const u8, source: [:0]const u8) ![]u32 {
    const tmp_src = try zioshade.compat.tempFilePathFmt(alloc, "msl_test_{s}.frag", .{name});
    defer alloc.free(tmp_src);
    const tmp_spv = try zioshade.compat.tempFilePathFmt(alloc, "msl_test_{s}.spv", .{name});
    defer alloc.free(tmp_spv);
    try zioshade.compat.writeFileAbsolute(alloc, tmp_src, std.mem.sliceTo(source, 0));
    const glslang = zioshade.compat.resolveVulkanTool(alloc, "glslangValidator") catch return error.SkipZigTest;
    defer alloc.free(glslang);
    var main_io = zioshade.compat.MainIo().init(alloc);
    defer main_io.deinit();
    const result = zioshade.compat.processRun(main_io.io(), alloc, &.{ glslang, "-V", tmp_src, "-o", tmp_spv }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const data = zioshade.compat.readFileAbsolute(alloc, tmp_spv, 1024 * 1024) catch return error.SkipZigTest;
    defer alloc.free(data);
    const words = try alloc.alloc(u32, data.len / 4);
    for (0..words.len) |i| words[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
    return words;
}

/// Compile a VERTEX GLSL shader → SPIR-V via glslang (the `.vert` extension infers
/// the stage). glslang wraps vertex outputs in a member-decorated `gl_PerVertex`
/// interface Block written via OpAccessChain+OpStore — the real Vulkan form that
/// zioshade's own frontend never emits (#471). Skips if glslang is unavailable.
fn compileVertToSpirv(name: []const u8, source: [:0]const u8) ![]u32 {
    const tmp_src = try zioshade.compat.tempFilePathFmt(alloc, "msl_test_{s}.vert", .{name});
    defer alloc.free(tmp_src);
    const tmp_spv = try zioshade.compat.tempFilePathFmt(alloc, "msl_test_{s}_vert.spv", .{name});
    defer alloc.free(tmp_spv);
    try zioshade.compat.writeFileAbsolute(alloc, tmp_src, std.mem.sliceTo(source, 0));
    const glslang = zioshade.compat.resolveVulkanTool(alloc, "glslangValidator") catch return error.SkipZigTest;
    defer alloc.free(glslang);
    var main_io = zioshade.compat.MainIo().init(alloc);
    defer main_io.deinit();
    const result = zioshade.compat.processRun(main_io.io(), alloc, &.{ glslang, "-V", tmp_src, "-o", tmp_spv }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!((result.term.exitedCode() orelse 1) == 0)) return error.SkipZigTest;
    const data = zioshade.compat.readFileAbsolute(alloc, tmp_spv, 1024 * 1024) catch return error.SkipZigTest;
    defer alloc.free(data);
    const words = try alloc.alloc(u32, data.len / 4);
    for (0..words.len) |i| words[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
    return words;
}

// ---------------------------------------------------------------------------
// #471: gl_PerVertex interface-block vertex outputs (external glslang/shaderc form).
// glslang writes gl_Position et al. as members of a member-decorated Block, via
// OpAccessChain<block> <member> + OpStore into an unnamed block instance — NOT the
// direct BuiltIn-decorated output vars zioshade's own frontend emits (so the rest of
// this suite never exercises this path). The MSL backend skipped the block entirely,
// producing `.gl_Position = v;` with an empty object name — invalid MSL for EVERY
// real Vulkan vertex shader. WGSL/GLSL/HLSL are already correct; oracle spirv-cross.
// ---------------------------------------------------------------------------

test "#471: glslang gl_PerVertex block promotes gl_Position to [[position]] (no empty-object store)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec3 pos;
        \\void main(){ gl_Position = vec4(pos, 1.0); }
    ;
    const spirv = compileVertToSpirv("pervertex_posonly", source) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    // gl_Position promoted into main0_out with the [[position]] attribute.
    try assertContains(msl, "gl_Position [[position]]");
    // Store targets the named output object, not an empty-object dangling ref.
    try assertContains(msl, "out.gl_Position");
    try assertNotContains(msl, " .gl_Position");
}

test "#471: glslang gl_PerVertex block promotes gl_PointSize to [[point_size]] (MSL has one, unlike HLSL)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec3 pos;
        \\void main(){ gl_Position = vec4(pos, 1.0); gl_PointSize = 2.0; }
    ;
    const spirv = compileVertToSpirv("pervertex_pointsize", source) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try assertContains(msl, "gl_Position [[position]]");
    // Metal HAS a point-size output, so promote (matches spirv-cross), not drop.
    try assertContains(msl, "gl_PointSize [[point_size]]");
    try assertContains(msl, "out.gl_PointSize");
}

// #470: the MSL FRAGMENT output is a hardcoded single `float4 _fragColor [[color(0)]]`
// (spirv_to_msl.zig). Multi-output fragments -- gl_FragDepth ([[depth(any)]]) and MRT
// (multiple color attachments) -- cannot be represented and previously emitted
// SILENT-WRONG / invalid MSL (depth scrambled into the color param, second color
// dropped). Per the wedge ("honest-error, never plausible-but-wrong"), reject them
// loudly until the proper multi-field main0_out rework lands (tracked separately).
// Single-color fragments are unaffected.
test "#470: MSL fragment writing gl_FragDepth honest-errors (not silent-invalid)" {
    const spirv = compileToSpirv("fragdepth_out",
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(1.0); gl_FragDepth = 0.25; }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedFragmentOutput, zioshade.spirvToMSL(alloc, spirv, .{}));
}

test "#470: MSL multiple color attachments (MRT) honest-error (not silent single-color)" {
    const spirv = compileToSpirv("mrt_two",
        \\#version 450
        \\layout(location=0) out vec4 a;
        \\layout(location=1) out vec4 b;
        \\void main(){ a = vec4(1.0); b = vec4(0.5); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedFragmentOutput, zioshade.spirvToMSL(alloc, spirv, .{}));
}

// #472-audit: SPIR-V OpSwitch cases do NOT fall through, but C++/Metal `switch` does
// without `break;`. MSL was emitting braced case bodies with NO break -> silent-wrong
// fallthrough. Each case must end with break;, matching GLSL and spirv-cross.
test "#472-audit: OpSwitch cases terminate with break; (no C fallthrough)" {
    const spirv = compileToSpirv("switch_break",
        \\#version 450
        \\layout(location=0) flat in int sel;
        \\layout(location=0) out vec4 c;
        \\void main(){ switch(sel){ case 0: c=vec4(1.0); break; case 1: c=vec4(0.5); break; default: c=vec4(0.2); break; } }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try assertContains(msl, "switch");
    try std.testing.expect(std.mem.count(u8, msl, "break;") >= 3);
}

/// glslang -> spirv-opt -O: produces SSA/phi form (glslang alone emits mutable locals
/// for branch-divergent values; -O runs mem2reg -> OpPhi). Needed to exercise the
/// loop-body merge-phi path. Skips if glslang OR spirv-opt is unavailable.
fn compileFragOptToSpirv(name: []const u8, source: [:0]const u8) ![]u32 {
    const tmp_src = try zioshade.compat.tempFilePathFmt(alloc, "msl_test_{s}.frag", .{name});
    defer alloc.free(tmp_src);
    const tmp_spv = try zioshade.compat.tempFilePathFmt(alloc, "msl_test_{s}.spv", .{name});
    defer alloc.free(tmp_spv);
    const tmp_opt = try zioshade.compat.tempFilePathFmt(alloc, "msl_test_{s}_opt.spv", .{name});
    defer alloc.free(tmp_opt);
    try zioshade.compat.writeFileAbsolute(alloc, tmp_src, std.mem.sliceTo(source, 0));
    const glslang = zioshade.compat.resolveVulkanTool(alloc, "glslangValidator") catch return error.SkipZigTest;
    defer alloc.free(glslang);
    const spirvopt = zioshade.compat.resolveVulkanTool(alloc, "spirv-opt") catch return error.SkipZigTest;
    defer alloc.free(spirvopt);
    var main_io = zioshade.compat.MainIo().init(alloc);
    defer main_io.deinit();
    const r1 = zioshade.compat.processRun(main_io.io(), alloc, &.{ glslang, "-V", tmp_src, "-o", tmp_spv }) catch return error.SkipZigTest;
    defer alloc.free(r1.stdout);
    defer alloc.free(r1.stderr);
    if ((r1.term.exitedCode() orelse 1) != 0) return error.SkipZigTest;
    const r2 = zioshade.compat.processRun(main_io.io(), alloc, &.{ spirvopt, "-O", tmp_spv, "-o", tmp_opt }) catch return error.SkipZigTest;
    defer alloc.free(r2.stdout);
    defer alloc.free(r2.stderr);
    if ((r2.term.exitedCode() orelse 1) != 0) return error.SkipZigTest;
    const data = zioshade.compat.readFileAbsolute(alloc, tmp_opt, 1024 * 1024) catch return error.SkipZigTest;
    defer alloc.free(data);
    const words = try alloc.alloc(u32, data.len / 4);
    for (0..words.len) |i| words[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
    return words;
}

// #474: a loop-body if/else whose two arms assign a value used after the merge
// (kept as a real if/else, e.g. conditional texture samples) lowers to an OpPhi at
// the merge. MSL's loop-body handler didn't materialize it, so the generic Phi
// fallback aliased the result to its FIRST incoming value -> the else branch's value
// was silently dropped (and its temp referenced out of scope). Must declare a _phi
// var assigned in BOTH arms, like emitBody/emitBlock and the other backends.
test "#474: MSL loop-body if/else merge-phi is materialized, not aliased to first arm" {
    const spirv = compileFragOptToSpirv("loopbody_phi",
        \\#version 450
        \\layout(binding=0) uniform sampler2D t;
        \\layout(location=0) in vec2 uv;
        \\layout(location=1) flat in int n;
        \\layout(location=2) flat in int cond;
        \\layout(location=0) out vec4 o;
        \\void main(){ vec4 acc=vec4(0.0); for(int i=0;i<n;i++){ vec4 v; if(cond>i){v=texture(t,uv*float(i));}else{v=texture(t,uv+float(i));} acc+=v; } o=acc; }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try assertContains(msl, "_phi");
    // Assigned in BOTH the if and else arms (not aliased to a single branch value).
    try std.testing.expect(std.mem.count(u8, msl, "_phi = ") >= 2);
}

// #475: MSL interpolation attributes on the fragment stage-in.
//  - Flat-on-FLOAT needs [[flat]] (Metal auto-flats only INTEGERS, not floats) -- the
//    prior MSL [[flat]]-on-integers change was reverted because integers don't need it;
//    floats do. Without it, MSL perspective-interpolates a flat value.
//  - NoPerspective needs [[center_no_perspective]].
// Oracle spellings verified against spirv-cross --msl.
test "#475: MSL Flat-on-float fragment input gets [[flat]]" {
    const spirv = compileToSpirv("flat_float_msl",
        \\#version 450
        \\layout(location=0) flat in vec3 color;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(color, 1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try assertContains(msl, "[[user(locn0), flat]]");
}

test "#475: MSL NoPerspective fragment input gets [[center_no_perspective]]" {
    const spirv = compileToSpirv("noperspective_msl",
        \\#version 450
        \\layout(location=0) noperspective in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(uv, 0.0, 1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try assertContains(msl, "[[user(locn0), center_no_perspective]]");
}

// #170: a do-while whose BODY has control flow (`if(...) continue;`) emits a NATIVE
// `do { … } while (<inlined cond>);`, which rebuilds the bottom condition over
// persistent vars via `tryInlineDoWhileCond`. With a FLOAT `!=` condition glslang
// emits an OpFUnordNotEqual back-edge, but the rebuild mapped only the ORDERED
// `.FOrdNotEqual` (plus the integer compare family) — `.FUnordNotEqual` fell through
// to `else => null`, so the caller honest-errored (`error.UnstructuredControlFlow`)
// even though MSL's `!=` is itself unordered (true on NaN) = exactly OpFUnordNotEqual,
// matching the main emitBinOp path. Reachable only via external SPIR-V (zioshade's
// frontend emits the ordered FOrdNotEqual for float `!=`).
test "T-dowhile.funord: do-while body-cf + float `!=` (OpFUnordNotEqual) -> native do/while (#170)" {
    const spirv = compileToSpirv("dowhile_funord_ne",
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float v = x;
        \\    do {
        \\        v += 1.0;
        \\        if (v == 3.0) continue;
        \\    } while (v != 10.0);
        \\    o = vec4(v);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try assertContains(msl, "} while (");
    try assertContains(msl, "!=");
    try assertContains(msl, "continue;");
}

// ---------------------------------------------------------------------------
// T1: MSL structure
// ---------------------------------------------------------------------------

test "T1.1: has metal_stdlib include" {
    const msl = try compileToMsl("#version 430\nvoid main() {}");
    defer alloc.free(msl);
    try assertContains(msl, "#include <metal_stdlib>");
    try assertContains(msl, "using namespace metal");
}

test "T1.2: fragment entry point" {
    const msl = try compileToMsl("#version 430\nvoid main() {}");
    defer alloc.free(msl);
    try assertContains(msl, "fragment");
}

test "T1.3: has color(0) output" {
    const msl = try compileToMsl("#version 430\nvoid main() {}");
    defer alloc.free(msl);
    try assertContains(msl, "[[color(0)]]");
}

// ---------------------------------------------------------------------------
// T2: MSL type names
// ---------------------------------------------------------------------------

test "T2.1: float4 not vec4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 color; } u;
        \\void main() { if (u.color.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4");
    try assertNotContains(msl, "vec4");
}

test "T2.2: float3 not vec3" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 pos; } u;
        \\void main() { if (u.pos.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3");
    try assertNotContains(msl, "vec3");
}

test "T2.3: float4x4 not mat4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 mvp; } u;
        \\void main() { vec4 p = u.mvp * vec4(1.0); if (p.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4x4");
    try assertNotContains(msl, "mat4");
}

test "T2.4: int4 not ivec4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { ivec4 data; } u;
        \\void main() { if (u.data.x > 0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "int4");
    try assertNotContains(msl, "ivec4");
}

// ---------------------------------------------------------------------------
// T3: MSL resource binding
// ---------------------------------------------------------------------------

test "T3.1: struct for uniform block" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float val; } u;
        \\void main() { if (u.val > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "struct");
}

test "T3.2: texture2d<float> not sampler2D" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<float>");
    try assertNotContains(msl, "sampler2D");
}

test "T3.3: buffer binding attribute" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float val; } u;
        \\void main() { if (u.val > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "[[buffer(");
}

test "SSBO emitted as a device reference with a sized runtime array (valid MSL, not silent-wrong)" {
    // Regression: SSBOs were emitted `device T* name` (pointer) but the body
    // accesses members with `.` — invalid C++/MSL (a pointer needs `->`). And a
    // runtime array `T[]` was emitted as a scalar `T;` then indexed `[0]`. Both
    // are silent-wrong (invalid MSL, exit 0). spirv-cross uses `device T&` + `T[1]`.
    const source =
        \\#version 450
        \\layout(local_size_x=1) in;
        \\layout(std430, binding=0) buffer Buf { uint cnt; float vals[]; } data;
        \\void main(){ data.cnt = 5u; data.vals[0] = 1.0; }
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    // Reference, not pointer (the body's `.` access is only valid on a reference).
    try assertContains(msl, "device data& data");
    try assertNotContains(msl, "device data* data");
    // Runtime array is sized `[1]` (so `vals[0]` is valid), never a bare scalar.
    try assertContains(msl, "vals[1]");
}

test "SSBO with a runtime array of structs still emits (no UnsupportedUboMemberLayout)" {
    // The runtime-array sizing fix must fall back to the plain element type for
    // struct elements (`Foo data[1]`), not throw — else a previously-emitting
    // shader regresses to an honest error.
    const source =
        \\#version 450
        \\layout(local_size_x=1) in;
        \\struct Foo { vec4 a; vec4 b; };
        \\layout(std430, binding=0) buffer SSBO { Foo items[]; } s;
        \\void main(){ s.items[0].a = vec4(1.0); }
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    // (zioshade names the buffer struct after the instance, `s`.) The point is it
    // emits as a reference and the struct-of array element is sized, not thrown.
    try assertContains(msl, "device s& s");
    try assertContains(msl, "Foo items[1]");
}

test "struct member after a VARIABLE array index emits .member, not [N] (silent-wrong)" {
    // Regression: the access-chain emitter only advanced cur_type for CONSTANT
    // indices, so after a variable array index (`arr[i]`) cur_type froze on the
    // array type and the following struct-member index emitted `[0]`/`[1]`
    // (numeric subscript on a struct — invalid MSL) instead of `.field`.
    const source =
        \\#version 450
        \\struct Light { vec3 color; float intensity; };
        \\layout(std140, binding=0) uniform U { Light lights[4]; } u;
        \\layout(location=0) flat in int idx;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.lights[idx].color * u.lights[idx].intensity, 1.0); }
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, ".color");
    try assertContains(msl, ".intensity");
    // The buggy numeric-subscript-on-struct form must NOT appear.
    try assertNotContains(msl, "[idx][0]");
}

test "nested struct in UBO: array element + std140 packing matches spirv-cross" {
    // A UBO containing an array of a nested struct exercises two paths that the
    // codegen std140 offset fix (#181) unmasked in the MSL backend:
    //   1. mslWidenedElementType must accept a TypeStruct element so the member
    //      emits `Light lights[4];` (was honest-error UnsupportedUboMemberLayout).
    //   2. the nested `Light` struct decl must be laid out std140-aware: a vec3
    //      followed by a tightly-packed scalar becomes `packed_float3` so the
    //      struct's natural MSL size (16) equals its std140 ArrayStride (16).
    //      Emitting plain `float3` would push `intensity` to offset 16, making
    //      Light 32 bytes and reading `lights[i]` at the wrong stride.
    // Oracle: spirv-cross --msl emits exactly `packed_float3 color; float
    // intensity;` inside Light and `Light lights[4];` inside the block.
    const source =
        \\#version 450
        \\struct Light { vec3 color; float intensity; };
        \\layout(std140, binding=0) uniform U { Light lights[4]; } u;
        \\layout(location=0) flat in int idx;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.lights[idx].color * u.lights[idx].intensity, 1.0); }
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    // Nested struct laid out to match std140 (packed vec3 so the scalar packs at
    // offset 12). `packed_float3` keeps Light at 16 bytes; the silent-wrong
    // `float3` form (16-byte aligned, pushing intensity to 16) would NOT have the
    // `packed_` prefix, so asserting its presence rules that bug out.
    try assertContains(msl, "packed_float3 color;");
    try assertContains(msl, "float intensity;");
    try assertContains(msl, "Light lights[4];");
}

test "T3.4: texture binding attribute" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "[[texture(");
    try assertContains(msl, "[[sampler(");
}

// ---------------------------------------------------------------------------
// T4: MSL texture sampling
// ---------------------------------------------------------------------------

test "T4.1: .sample() not texture()" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, ".sample(");
    try assertNotContains(msl, "Sample(");
}

// ---------------------------------------------------------------------------
// T5: MSL built-in functions
// ---------------------------------------------------------------------------

test "T5.1: powr not pow" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { if (pow(u.a, u.b) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "powr(");
    try assertNotContains(msl, "pow(");
}

test "T5.2: rsqrt not inversesqrt" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (inversesqrt(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "rsqrt(");
    try assertNotContains(msl, "inversesqrt");
}

test "T5.3: sin" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (sin(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "sin(");
}

test "T5.4: cos" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (cos(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "cos(");
}

test "T5.5: abs" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (abs(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "abs(");
}

test "T5.6: mix" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; float t; } u;
        \\void main() { if (mix(u.a, u.b, u.t) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "mix(");
    try assertNotContains(msl, "lerp");
}

test "T5.7: fract" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (fract(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "fract(");
}

test "T5.8: floor" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { float f = floor(u.a); if (f > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "floor(");
}

test "T5.9: sqrt" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (sqrt(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "sqrt(");
}

test "T5.10: min/max" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { if (min(u.a, u.b) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "min(");
}

test "T5.11: fast::clamp for scalar clamp" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (clamp(u.a, 0.0, 1.0) > 0.5) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "clamp(");
}

test "T5.12: dot product" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 a; vec3 b; } u;
        \\void main() { float d = dot(u.a, u.b); if (d > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "dot(");
}

test "T5.13: transpose" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 m; } u;
        \\void main() { mat4 t = transpose(u.m); vec4 p = t * vec4(1.0); if (p.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "transpose(");
}

// ---------------------------------------------------------------------------
// T6: MSL control flow
// ---------------------------------------------------------------------------

test "T6.1: discard_fragment not discard" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (u.a < 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "discard_fragment()");
}

test "T6.2: if-else" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() {
        \\    float b;
        \\    if (u.a > 0.5) { b = 1.0; } else { b = 0.0; }
        \\    if (b > 0.0) discard;
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "if");
    try assertContains(msl, "else");
}

// ---------------------------------------------------------------------------
// T7: MSL entry point
// ---------------------------------------------------------------------------

test "T7.1: position attribute" {
    const source =
        \\#version 430
        \\void main() { vec2 uv = gl_FragCoord.xy; if (uv.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "[[position]]");
}

test "T7.2: thread float4& for out params" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\void main() { if (u.a.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Verify output struct exists
    try assertContains(msl, "main0_out");
}

// ---------------------------------------------------------------------------
// T8: MSL arithmetic
// ---------------------------------------------------------------------------

test "T8.1: addition" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { float c = u.a + u.b; if (c > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "+");
}

test "T8.2: multiplication" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { float c = u.a * u.b; if (c > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "*");
}

test "T8.3: vector arithmetic" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
        \\void main() { vec4 c = u.a + u.b; if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4");
    try assertContains(msl, "+");
}

test "T8.4: matrix times vector" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 mvp; vec4 pos; } u;
        \\void main() { vec4 c = u.mvp * u.pos; if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4x4");
    try assertContains(msl, "*");
}

// ---------------------------------------------------------------------------
// T9: MSL type conversions
// ---------------------------------------------------------------------------

test "T9.1: int to float conversion" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int a; } u;
        \\void main() { float f = float(u.a); if (f > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float(");
}

// ---------------------------------------------------------------------------
// T10: MSL-specific (not GLSL or HLSL)
// ---------------------------------------------------------------------------

test "T10.1: no #version" {
    const msl = try compileToMsl("#version 430\nvoid main() {}");
    defer alloc.free(msl);
    try assertNotContains(msl, "#version");
}

test "T10.2: no cbuffer" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (u.a > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertNotContains(msl, "cbuffer");
}

test "T10.3: no register()" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (u.a > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertNotContains(msl, "register(");
}

// ---------------------------------------------------------------------------
// T11: Complex expressions
// ---------------------------------------------------------------------------

test "T11.1: nested arithmetic" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; float c; } u;
        \\void main() { float d = (u.a + u.b) * u.c; if (d > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "+");
    try assertContains(msl, "*");
}

test "T11.2: swizzle access" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\void main() { float x = u.a.x; if (x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, ".x");
}

// === Subgroup operation tests (Issue #3) ===

test "subgroupAll compiles to MSL with simd_all" {
    const source =
        \\#version 450
        \\#extension GL_KHR_shader_subgroup_vote : enable
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer Data { float values[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    bool all_pos = subgroupAll(values[idx] > 0.0);
        \\    if (all_pos) { values[idx] = 1.0; }
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "simd_all");
}

test "subgroupAny compiles to MSL with simd_any" {
    const source =
        \\#version 450
        \\#extension GL_KHR_shader_subgroup_vote : enable
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer Data { float values[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    bool any_pos = subgroupAny(values[idx] > 0.0);
        \\    if (any_pos) { values[idx] = 1.0; }
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "simd_any");
}

// === FP16 type tests (Issue #4) ===

test "float16_t compiles through the pipeline" {
    const source =
        \\#version 450
        \\#extension GL_EXT_shader_explicit_arithmetic_types_float16 : enable
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { if (u.a + u.b > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Just verify it compiles without error
    try assertContains(msl, "metal_stdlib");
}

test "CBUFFER_ACCESS: MSL struct member access uses source member name not array index" {
    // De-false-greened: previously asserted the BROKEN synthesized `_m0`/`_m1`
    // names appeared in the struct decl while the body used the SOURCE names
    // (Globals_1.iTime) — a decl<->body mismatch that produced non-compiling
    // MSL. spirv-cross --msl uses the SOURCE OpMemberName (`iResolution`,
    // `iTime`) in BOTH the decl and the body. Assert that here.
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform Globals {
        \\    uniform vec3 iResolution;
        \\    uniform float iTime;
        \\};
        \\layout(location = 0) out vec4 _fragColor;
        \\void main() {
        \\    float t = iTime;
        \\    _fragColor = vec4(t, t, t, 1.0);
        \\}
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    // Must NOT use array indexing for struct member access
    try assertNotContains(msl, "Globals[0]");
    try assertNotContains(msl, "Globals[1]");
    // Decl must use the SOURCE member names (matching the body refs).
    try assertContains(msl, "packed_float3 iResolution;");
    try assertContains(msl, "float iTime;");
    // No synthesized index names anywhere.
    try assertNotContains(msl, "_m0");
    try assertNotContains(msl, "_m1");
    // Body references the same source name.
    try assertContains(msl, "Globals_1.iTime");
}

test "msl: bitfieldReverse -> reverse_bits" {
    const src =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    uint a = bitfieldReverse(1u);
        \\    fragColor = vec4(float(a));
        \\}
    ;
    const spv = try zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const msl = try zioshade.spirvToMSL(alloc, spv, .{});
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "reverse_bits") != null);
}

test "msl: bitCount -> popcount" {
    const src =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int a = bitCount(1u);
        \\    fragColor = vec4(float(a));
        \\}
    ;
    const spv = try zioshade.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const msl = try zioshade.spirvToMSL(alloc, spv, .{});
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "popcount") != null);
}

test "T11.1: MSL loop reconstruction produces while loop" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int n; float x; } u;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < u.n; i++) {
        \\        sum += u.x;
        \\        if (sum > 10.0) break;
        \\    }
        \\    if (sum > 0.0) discard;
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // MSL backend should reconstruct loops as while(true)
    try assertContains(msl, "while");
    try assertContains(msl, "break");
    try assertContains(msl, "discard_fragment");
}

test "T-bits.0: findLSB/findMSB in MSL lower to the guarded index idiom, not bare ctz/clz" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\layout(binding = 0) uniform U { int seed; } u;
        \\void main() {
        \\    int a = findLSB(u.seed);
        \\    int b = findMSB(u.seed);
        \\    fragColor = vec4(float(a), float(b), 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // findLSB → select(ctz(x), -1, x==0); findMSB(signed) → flip + select(clz-index).
    // NOT the old bare ctz/clz (which returned the wrong count / missed the zero edge).
    try assertContains(msl, "select(ctz(");
    try assertContains(msl, "select(clz(");
    try assertContains(msl, "_fmsb_"); // signed findMSB negative-flip temp
    try assertNotContains(msl, " = ctz(");
    try assertNotContains(msl, " = clz(");
}

test "T12.1: MSL CompositeInsert (partial vector write)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
        \\    v.x = 5.0;
        \\    fragColor = v;
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Should not contain "unhandled op" for CompositeInsert
    try assertNotContains(msl, "unhandled op");
    // Should contain assignment to swizzle component
    try assertContains(msl, ".x");
}

test "msl: frexp (FrexpStruct std450 #52)" {
    const src =
        \\#version 450
        \\layout(location = 0) in float v0;
        \\layout(location = 0) out float fragColor;
        \\void main() {
        \\    int e;
        \\    float f = frexp(v0, e);
        \\    fragColor = f + float(e);
        \\}
    ;
    const msl = try compileToMsl(src);
    defer alloc.free(msl);
    try assertContains(msl, "frexp(");
    try assertNotContains(msl, "ResType");
    try assertNotContains(msl, "unhandled");
    // The location input `v0` must be plumbed through the stage-in struct,
    // not referenced bare (was false-green: only checked for `frexp(`).
    try assertContains(msl, "float v0 [[user(locn0)]];");
    try assertContains(msl, "main0_in in [[stage_in]]");
    try assertContains(msl, "frexp(in.v0");
}

test "msl: modf (ModfStruct std450 #36)" {
    const src =
        \\#version 450
        \\layout(location = 0) in float v0;
        \\layout(location = 0) out float fragColor;
        \\void main() {
        \\    float whole;
        \\    float frac_part = modf(v0, whole);
        \\    fragColor = frac_part + whole;
        \\}
    ;
    const msl = try compileToMsl(src);
    defer alloc.free(msl);
    try assertContains(msl, "modf(");
    try assertNotContains(msl, "ResType");
    try assertNotContains(msl, "unhandled");
    // The location input `v0` must be plumbed through the stage-in struct,
    // not referenced bare (was false-green: only checked for `modf(`).
    try assertContains(msl, "float v0 [[user(locn0)]];");
    try assertContains(msl, "main0_in in [[stage_in]]");
    try assertContains(msl, "modf(in.v0");
}

test "MSL: local array variable declaration" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 u; } ubo;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    float a[4];
        \\    a[0] = ubo.u.x;
        \\    a[1] = ubo.u.y;
        \\    a[2] = ubo.u.z;
        \\    a[3] = ubo.u.w;
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 4; i++) sum += a[i];
        \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "[4]");
}

test "MSL: nested struct member access in AccessChain" {
    const source =
        \\#version 430
        \\struct Inner { vec4 a; float b; };
        \\struct Outer { Inner sub; float c; };
        \\layout(binding = 0, std140) uniform U { Outer data; } ubo;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    FragColor = ubo.data.sub.a + vec4(ubo.data.c);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Should use .sub and .a for struct member access, not [0]
    try assertContains(msl, ".sub");
    try assertContains(msl, ".a");
}

// textureGatherOffsets lowers (correctly, for the SPIR-V target) to
// OpImageGather carrying the ConstOffsets image operand — a per-texel
// 4-offset array. MSL's `tex.gather(...)` cannot take a 4-offset array, so the
// MSL backend must FAIL LOUDLY rather than silently emit a plain `.gather`
// that drops the offsets (silent-wrong cross-compile).
test "msl: textureGatherOffsets (ConstOffsets) is an honest error, not a silent plain gather" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  const ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs, 1);
        \\}
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(
        error.UnsupportedImageOperands,
        zioshade.spirvToMSL(alloc, spirv, .{}),
    );
}

// ---------------------------------------------------------------------------
// T15: Fragment stage inputs ([[stage_in]] / main0_in plumbing)
//
// Reference shape from spirv-cross --msl (the oracle): location-decorated
// fragment Input variables must be gathered into a `struct main0_in` with
// `T name [[user(locnN)]]` fields, threaded into the entry via
// `main0_in in [[stage_in]]`, and referenced in the body as `in.<name>`.
// zioshade keeps its `main0_impl` helper factoring, so `in` is also threaded
// into `main0_impl` by value. The previously-emitted MSL referenced bare,
// undeclared input variables (e.g. `uv.x`) — non-compiling MSL at exit 0.
// ---------------------------------------------------------------------------

test "T15.1: single location input → main0_in + [[stage_in]] + in.<name>" {
    const source =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(uv, 0.0, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The input struct exists with the correct field + user(locn0) attribute.
    try assertContains(msl, "struct main0_in");
    try assertContains(msl, "float2 uv [[user(locn0)]];");
    // The entry takes the stage-in struct.
    try assertContains(msl, "main0_in in [[stage_in]]");
    // The body references the input through the struct, not the bare name.
    try assertContains(msl, "in.uv");
    // No bare, undeclared input reference may survive (non-compiling MSL).
    try assertNotContains(msl, "float v9 = uv.x");
    try assertNotContains(msl, " = uv.x");
    try assertNotContains(msl, " = uv.y");
}

test "T15.2: multiple location inputs ordered by location" {
    const source =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 1) in vec4 color;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(uv, 0.0, 1.0) * color; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "struct main0_in");
    try assertContains(msl, "float2 uv [[user(locn0)]];");
    try assertContains(msl, "float4 color [[user(locn1)]];");
    try assertContains(msl, "main0_in in [[stage_in]]");
    // Both inputs threaded through the struct in the body.
    try assertContains(msl, "in.uv");
    try assertContains(msl, "in.color");
    // Ordering: locn0 field precedes locn1 field (match spirv-cross order).
    const i_uv = std.mem.indexOf(u8, msl, "uv [[user(locn0)]]").?;
    const i_color = std.mem.indexOf(u8, msl, "color [[user(locn1)]]").?;
    try std.testing.expect(i_uv < i_color);
}

test "T15.3: access-chain/swizzle on a location input resolves off in.<name>" {
    // Two forms exercised together:
    //   - color.x/.y/.z  → AccessChain + swizzleChar → `in.color.x` etc.
    //   - color.xyz      → VectorShuffle → `in.color[0]` etc. (array-index form)
    // Both must resolve through the stage-in struct member; neither may leave a
    // bare, undeclared `color` reference behind.
    const source =
        \\#version 450
        \\layout(location = 0) in vec4 color;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(color.x, color.y, color.z, 1.0) + vec4(color.xyz, 0.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "struct main0_in");
    try assertContains(msl, "float4 color [[user(locn0)]];");
    try assertContains(msl, "main0_in in [[stage_in]]");
    // Swizzle/access-chain must resolve off the struct member (both forms).
    try assertContains(msl, "in.color.x");
    try assertContains(msl, "in.color[0]");
    // Never a bare swizzle/index on an undeclared input.
    try assertNotContains(msl, " = color.x");
    try assertNotContains(msl, "float3(color[0]");
}

test "T15.4: gl_FragCoord and a location input coexist" {
    const source =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(uv, gl_FragCoord.x, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // gl_FragCoord stays on its builtin [[position]] path...
    try assertContains(msl, "float4 gl_FragCoord [[position]]");
    // ...and must NOT leak into main0_in.
    try assertNotContains(msl, "gl_FragCoord [[user(");
    // The location input is in the stage-in struct and used via `in.`.
    try assertContains(msl, "struct main0_in");
    try assertContains(msl, "float2 uv [[user(locn0)]];");
    try assertContains(msl, "main0_in in [[stage_in]]");
    try assertContains(msl, "in.uv");
}

test "T15.5: int location input emits int field (matches spirv-cross, no [[flat]])" {
    const source =
        \\#version 450
        \\layout(location = 0) flat in int idx;
        \\layout(location = 1) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(uv, float(idx), 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "struct main0_in");
    try assertContains(msl, "int idx [[user(locn0)]];");
    try assertContains(msl, "float2 uv [[user(locn1)]];");
    try assertContains(msl, "in.idx");
    try assertContains(msl, "in.uv");
}

// #478: a location-decorated Input interface block `layout(location=L) in Block
// { members } vin;` was skipped by collectStageInputs (struct-typed), so body
// access `vin.member` referenced an undeclared `vin`. Flatten each member into
// its own `T <inst>_<member> [[user(locnK)]]` stage-in field (location base+index)
// and rewrite `vin.member` to `in.<inst>_<member>`.
test "T15.7: interface-block input is flattened into main0_in fields (#478)" {
    const source: [:0]const u8 =
        \\#version 310 es
        \\#extension GL_EXT_shader_io_blocks : require
        \\precision mediump float;
        \\layout(location = 1) in VertexOut { vec4 color; highp vec3 normal; } vin;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vin.color + vin.normal.xyzz; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Members flattened to distinct stage-in fields at sequential locations.
    try assertContains(msl, "vin_color [[user(locn1)]];");
    try assertContains(msl, "vin_normal [[user(locn2)]];");
    // Body resolves members through the stage-in struct, not a bare `vin`.
    try assertContains(msl, "in.vin_color");
    try assertContains(msl, "in.vin_normal");
    try assertNotContains(msl, "vin.color");
    try assertNotContains(msl, "vin.normal");
}

test "T15.6: no location inputs → no main0_in struct (no regression)" {
    const source =
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec4 color; } u;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = u.color; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // A uniform-only fragment shader must not grow a spurious stage-in.
    try assertNotContains(msl, "struct main0_in");
    try assertNotContains(msl, "[[stage_in]]");
}

// #479: a fragment with NO Output variable (only side effects / discard). The
// impl signature already omits the `thread float4& _fragColor` output param, but
// the entry wrapper still passed `out._fragColor` -> arg-count mismatch ("no
// matching function for call to main0_impl"). Gate the output argument on the
// output var, matching the signature.
test "T-zerooutput.msl: fragment with no output emits a matching impl call (#479)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\void main() { if (uv.x > 0.5) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The call must not pass the color output the impl no longer accepts.
    try assertContains(msl, "main0_impl(gl_FragCoord");
    try assertNotContains(msl, "main0_impl(out._fragColor");
}

// #480: mutually-recursive functions (funcA calls funcB defined later, and vice
// versa) referenced an undeclared callee because non-entry functions are emitted
// in definition order with no forward prototypes. Emit C prototypes for all
// non-entry functions first when a forward call exists.
test "T-mutualrec.msl: mutual recursion gets forward prototypes (#480)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\float funcA(int n);
        \\float funcB(int n);
        \\float funcA(int n) { if (n <= 0) return 1.0; return float(n) * funcB(n - 1); }
        \\float funcB(int n) { if (n <= 0) return 1.0; return float(n) * funcA(n - 1); }
        \\void main() { fragColor = vec4(funcA(int(uv.x * 4.0) + 1), 0.0, 0.0, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // A forward prototype precedes the funcB body so funcA's call resolves.
    const proto = std.mem.indexOf(u8, msl, "funcB(") orelse return error.TestExpectedFind;
    const body = std.mem.lastIndexOf(u8, msl, "funcB(") orelse return error.TestExpectedFind;
    try std.testing.expect(proto < body); // at least two occurrences (proto + def)
    try assertContains(msl, ");\nfloat "); // a `);` prototype line precedes a definition
}

// #481: gl_SampleMaskIn is an int[] in GLSL but Metal's [[sample_mask]] is a
// scalar uint. Thread it as a fragment entry param and drop the `[0]` array
// index so the body reads the scalar (was an undeclared identifier before).
test "T-samplemask.msl: gl_SampleMaskIn maps to scalar [[sample_mask]] (#481)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(gl_SampleMaskIn[0]); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "uint gl_SampleMaskIn [[sample_mask]]");
    // The GLSL array index is dropped: no `gl_SampleMaskIn[0]` survives.
    try assertNotContains(msl, "gl_SampleMaskIn[0]");
}

// #482: OpImageQueryLevels (textureQueryLevels) had no MSL emit arm, so its
// result id was undefined ("unhandled op 106"). Map it to get_num_mip_levels().
test "T-querylevels.msl: textureQueryLevels maps to get_num_mip_levels() (#482)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vec4(float(textureQueryLevels(tex))); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "get_num_mip_levels()");
    try assertNotContains(msl, "unhandled op");
}

// #483: a push_constant block was never gathered by collectResources (no
// .PushConstant case), so body references (push.value0) were undeclared. Emit it
// as a UBO-style `constant T& name_1 [[buffer(N)]]` buffer and qualify member
// access through the same `_1` path (isUniformVar now recognizes PushConstant).
test "T-pushconstant.msl: push_constant block emits a constant buffer (#483)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(push_constant, std430) uniform PushConstants { vec4 v0; vec4 v1; } push;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = push.v0 + push.v1; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "constant push& push_1");
    // Member access goes through the buffer instance, not the bare struct type.
    try assertContains(msl, "push_1.v0");
    try assertNotContains(msl, " = push.v0");
}

// ---------------------------------------------------------------------------
// T16: VERTEX stage I/O (mirrors T15 fragment, structurally matched to
// spirv-cross --msl). Vertex inputs use `[[attribute(N)]]` (NOT
// `[[user(locnN)]]`); a `main0_out` struct carries user varyings
// `[[user(locnN)]]` followed by `gl_Position [[position]]`; the entry keyword
// is `vertex` and returns `main0_out`; body refs are `in.<name>`/`out.<name>`
// and gl_Position becomes the struct field `out.gl_Position`, never a local.
//
// Oracle (spirv-cross 1.4.341.1) for the single in+out shape:
//   struct main0_out { float2 vUV [[user(locn0)]]; float4 gl_Position [[position]]; };
//   struct main0_in  { float3 aPos [[attribute(0)]]; float2 aUV [[attribute(1)]]; };
//   vertex main0_out main0(main0_in in [[stage_in]]) {
//       main0_out out = {};
//       out.vUV = in.aUV;
//       out.gl_Position = float4(in.aPos, 1.0);
//       return out;
//   }
// ---------------------------------------------------------------------------

test "T16.1: single location input + varying + gl_Position" {
    const source =
        \\#version 450
        \\layout(location = 0) in vec3 aPos;
        \\layout(location = 1) in vec2 aUV;
        \\layout(location = 0) out vec2 vUV;
        \\void main() { vUV = aUV; gl_Position = vec4(aPos, 1.0); }
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    // Entry wrapper: vertex keyword, returns main0_out, takes stage-in struct.
    try assertContains(msl, "vertex main0_out main0(main0_in in [[stage_in]]");
    // Inputs use [[attribute(N)]], NOT [[user(locnN)]].
    try assertContains(msl, "struct main0_in");
    try assertContains(msl, "float3 aPos [[attribute(0)]];");
    try assertContains(msl, "float2 aUV [[attribute(1)]];");
    try assertNotContains(msl, "aPos [[user(");
    // Outputs: user varying via [[user(locnN)]], gl_Position via [[position]].
    try assertContains(msl, "struct main0_out");
    try assertContains(msl, "float2 vUV [[user(locn0)]];");
    try assertContains(msl, "float4 gl_Position [[position]];");
    // Body refs through the structs. (zioshade decomposes vec constructors into
    // intermediate vars — `in.aPos.x` etc. — then assigns; the structural fact
    // is that the input resolves off `in.` and the store target off `out.`.)
    try assertContains(msl, "out.vUV = in.aUV");
    try assertContains(msl, "in.aPos.x");
    // gl_Position is written as the struct FIELD out.gl_Position, never a local.
    try assertContains(msl, "out.gl_Position =");
    try assertNotContains(msl, "float4 gl_Position =");
    try assertNotContains(msl, "    gl_Position =");
    // The entry materializes `main0_out out = {};` and returns it.
    try assertContains(msl, "main0_out out = {};");
    try assertContains(msl, "return out;");
}

test "T16.2: gl_Position only — no varyings still yields a main0_out [[position]]" {
    const source =
        \\#version 450
        \\layout(location = 0) in vec3 aPos;
        \\void main() { gl_Position = vec4(aPos, 1.0); }
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    try assertContains(msl, "vertex main0_out main0(main0_in in [[stage_in]]");
    try assertContains(msl, "struct main0_in");
    try assertContains(msl, "float3 aPos [[attribute(0)]];");
    // main0_out carries ONLY gl_Position (no user varyings).
    try assertContains(msl, "struct main0_out");
    try assertContains(msl, "float4 gl_Position [[position]];");
    try assertNotContains(msl, "[[user(locn");
    // gl_Position is a field, not a local.
    try assertContains(msl, "out.gl_Position =");
    try assertContains(msl, "in.aPos.x");
    try assertNotContains(msl, "float4 gl_Position =");
}

test "T16.3: multiple varyings ordered by location, then gl_Position last" {
    const source =
        \\#version 450
        \\layout(location = 0) in vec3 aPos;
        \\layout(location = 1) in vec2 aUV;
        \\layout(location = 2) in vec3 aNormal;
        \\layout(location = 0) out vec2 vUV;
        \\layout(location = 1) out vec3 vNormal;
        \\void main() { vUV = aUV; vNormal = aNormal; gl_Position = vec4(aPos, 1.0); }
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    // Inputs in attribute order.
    try assertContains(msl, "float3 aPos [[attribute(0)]];");
    try assertContains(msl, "float2 aUV [[attribute(1)]];");
    try assertContains(msl, "float3 aNormal [[attribute(2)]];");
    // Outputs ordered: varyings by location, gl_Position LAST.
    try assertContains(msl, "float2 vUV [[user(locn0)]];");
    try assertContains(msl, "float3 vNormal [[user(locn1)]];");
    try assertContains(msl, "float4 gl_Position [[position]];");
    const i_vuv = std.mem.indexOf(u8, msl, "vUV [[user(locn0)]]").?;
    const i_vnorm = std.mem.indexOf(u8, msl, "vNormal [[user(locn1)]]").?;
    const i_glpos = std.mem.indexOf(u8, msl, "gl_Position [[position]]").?;
    try std.testing.expect(i_vuv < i_vnorm);
    try std.testing.expect(i_vnorm < i_glpos);
    // Body refs.
    try assertContains(msl, "out.vUV = in.aUV");
    try assertContains(msl, "out.vNormal = in.aNormal");
    try assertContains(msl, "out.gl_Position =");
    try assertContains(msl, "in.aPos.x");
}

test "T16.4: vertex with a UBO threads the cbuffer and stage-in together" {
    const source =
        \\#version 450
        \\layout(binding = 0, std140) uniform U { mat4 mvp; } u;
        \\layout(location = 0) in vec3 aPos;
        \\layout(location = 0) out vec3 vPos;
        \\void main() { vPos = aPos; gl_Position = u.mvp * vec4(aPos, 1.0); }
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    // The UBO struct is emitted (zioshade names it after the instance var `u`
    // with a float4x4 member — its own convention, not spirv-cross's `struct U`).
    try assertContains(msl, "struct u");
    try assertContains(msl, "float4x4");
    // Entry threads BOTH the stage-in struct AND the cbuffer via [[buffer(0)]].
    try assertContains(msl, "vertex main0_out main0(main0_in in [[stage_in]]");
    try assertContains(msl, "[[buffer(0)]]");
    // The cbuffer is passed into the impl as `u_1` (matches the fragment path).
    try assertContains(msl, "constant u& u_1");
    // Body uses the stage-in input.
    try assertContains(msl, "struct main0_in");
    try assertContains(msl, "float3 aPos [[attribute(0)]];");
    try assertContains(msl, "out.vPos = in.aPos");
    // gl_Position written as struct field (multiplied by the matrix).
    try assertContains(msl, "out.gl_Position =");
    try assertNotContains(msl, "float4 gl_Position =");
}

test "T16.5: swizzle/access-chain on input and output resolve off in./out." {
    const source =
        \\#version 450
        \\layout(location = 0) in vec4 aPos;
        \\layout(location = 0) out vec3 vRGB;
        \\void main() { vRGB = aPos.xyz; gl_Position = vec4(aPos.x, aPos.y, aPos.z, 1.0); }
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    try assertContains(msl, "float4 aPos [[attribute(0)]];");
    try assertContains(msl, "float3 vRGB [[user(locn0)]];");
    try assertContains(msl, "float4 gl_Position [[position]];");
    // Swizzle on the input resolves through in.<name>.
    try assertContains(msl, "in.aPos.x");
    // The varying store target resolves through out.<name>.
    try assertContains(msl, "out.vRGB =");
    try assertContains(msl, "out.gl_Position =");
    // Never a bare undeclared input/output reference.
    try assertNotContains(msl, " = aPos.x");
    try assertNotContains(msl, "float4 gl_Position =");
}

test "T16.6: NOT a bare void main0 — vertex must have the entry wrapper" {
    // Direct regression guard for the original bug: zioshade used to emit
    // `void main0()` referencing undeclared aPos/aUV/vUV/gl_Position.
    const source =
        \\#version 450
        \\layout(location = 0) in vec3 aPos;
        \\layout(location = 1) in vec2 aUV;
        \\layout(location = 0) out vec2 vUV;
        \\void main() { vUV = aUV; gl_Position = vec4(aPos, 1.0); }
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    try assertNotContains(msl, "void main0()");
    try assertContains(msl, "vertex main0_out main0(");
}

// ---------------------------------------------------------------------------
// T17: UBO struct member names must match body refs (no synthesized _mN in the
// struct DECL while the body uses .mvp/.tint). Mirrors spirv-cross --msl, which
// emits the SOURCE member name (OpMemberName) in BOTH the struct decl and the
// body, with NO [[offset(N)]] attribute (relies on natural MSL layout matching
// std140).
//
// The pre-fix bug: emitStructMembers synthesized `_m{i} [[offset(N)]]` for the
// DECL while writeAccessExpr emitted `.mvp`/`.tint` for the BODY → mismatch →
// non-compiling MSL for ANY UBO with named members.
// ---------------------------------------------------------------------------

test "T17.1: UBO mat4+vec4 — struct decl member names match body refs" {
    // The exact repro. spirv-cross oracle:
    //   struct U { float4x4 mvp; float4 tint; };
    //   ... (u.mvp * float4(in.uv, 0.0, 1.0)) + u.tint;
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat4 mvp; vec4 tint; } u;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main() { o = u.mvp*vec4(uv,0,1)+u.tint; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // DECL uses the SOURCE member names (matches the body's u_1.mvp/.tint).
    try assertContains(msl, "float4x4 mvp;");
    try assertContains(msl, "float4 tint;");
    // No synthesized index names in the struct decl.
    try assertNotContains(msl, "_m0");
    try assertNotContains(msl, "_m1");
    // spirv-cross emits no [[offset]] on a constant buffer struct member.
    try assertNotContains(msl, "[[offset(");
    // Body still references the same names (consistency decl<->body).
    try assertContains(msl, "u_1.mvp");
    try assertContains(msl, "u_1.tint");
}

test "T17.2: UBO vec2+scalar — source names, no offset, natural layout" {
    // spirv-cross: struct U { float2 a; float b; };
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec2 a; float b; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a, u.b, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float2 a;");
    try assertContains(msl, "float b;");
    try assertNotContains(msl, "_m0");
    try assertNotContains(msl, "_m1");
    try assertNotContains(msl, "[[offset(");
}

test "T17.3: multiple scalars tightly packed — source names, natural layout" {
    // spirv-cross: struct U { float a; float b; float2 c; int d; };
    // std140 offsets 0,4,8,16 == natural MSL offsets.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { float a; float b; vec2 c; int d; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a, u.b, u.c) * float(u.d); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float a;");
    try assertContains(msl, "float b;");
    try assertContains(msl, "float2 c;");
    try assertContains(msl, "int d;");
    try assertNotContains(msl, "_m");
    try assertNotContains(msl, "[[offset(");
}

test "T17.4: two UBOs — both use source member names" {
    // NOTE: the two blocks must have STRUCTURALLY DISTINCT member layouts.
    // Two byte-identical UBO struct types (e.g. both `{ vec4 x; }`) hit a
    // SEPARATE pre-existing collision in the SPIR-V parser's id resolution:
    // both variables resolve to the same struct type_id, so the SECOND block's
    // member names alias the first's (in BOTH decl and body — predates this
    // member-name fix). That identical-struct collision is out of scope here
    // and noted as a follow-up; this test pins the member-name-consistency
    // property for the (common) distinct-layout case.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform A { vec4 ca; } a;
        \\layout(binding=1,std140) uniform B { vec2 cb; float cc; } b;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.ca + vec4(b.cb, b.cc, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4 ca;");
    try assertContains(msl, "float2 cb;");
    try assertContains(msl, "float cc;");
    // Body references the source names consistently with the decl.
    try assertContains(msl, "a_1.ca");
    try assertContains(msl, "b_1.cb");
    try assertContains(msl, "b_1.cc");
    try assertNotContains(msl, "_m0");
    try assertNotContains(msl, "[[offset(");
}

test "T17.5: vertex-stage UBO — struct decl matches body refs" {
    // The same bug afflicts the vertex path. spirv-cross oracle decl: float4x4 mvp;
    const source =
        \\#version 450
        \\layout(binding = 0, std140) uniform U { mat4 mvp; } u;
        \\layout(location = 0) in vec3 aPos;
        \\layout(location = 0) out vec3 vPos;
        \\void main() { vPos = aPos; gl_Position = u.mvp * vec4(aPos, 1.0); }
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    try assertContains(msl, "float4x4 mvp;");
    try assertNotContains(msl, "_m0");
    try assertNotContains(msl, "[[offset(");
    try assertContains(msl, "u_1.mvp");
}

test "T17.6: vec3 followed by scalar — packed_float3 (b at offset 12), no offset attr" {
    // std140: a at 0 (size 12), b at 12. MSL packed_float3 (12 bytes) + float
    // gives b at 12 naturally, matching std140. spirv-cross:
    //   struct U { packed_float3 a; float b; };
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec3 a; float b; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a, u.b); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "packed_float3 a;");
    try assertContains(msl, "float b;");
    try assertNotContains(msl, "_m0");
    try assertNotContains(msl, "[[offset(");
}

test "T17.7: vec3 followed by 16-aligned member — float3 (16-byte), no offset attr" {
    // DIVERGENT layout case: std140 puts b at offset 16, but packed_float3 (12
    // bytes) would place b at 12 naturally — WRONG. spirv-cross promotes the
    // vec3 to float3 (16-byte aligned) so b lands at 16 without an [[offset]]:
    //   struct U { float3 a; float3 b; };
    // Dropping [[offset]] with packed_float3 here would be silent-wrong layout.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec3 a; vec3 b; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a + u.b, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Must promote to float3 (16-byte) so natural layout == std140 (b at 16).
    try assertContains(msl, "float3 a;");
    try assertContains(msl, "float3 b;");
    try assertNotContains(msl, "packed_float3");
    try assertNotContains(msl, "_m0");
    try assertNotContains(msl, "[[offset(");
}

test "T17.8: single trailing vec3 — float3 (matches spirv-cross), no offset attr" {
    // spirv-cross uses float3 (not packed) for a lone/trailing vec3:
    //   struct U { float3 pos; };
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec3 pos; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.pos, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3 pos;");
    try assertNotContains(msl, "packed_float3");
    try assertNotContains(msl, "_m0");
    try assertNotContains(msl, "[[offset(");
}

// ---------------------------------------------------------------------------
// T18: UBO matrix + array std140 layout must MATCH spirv-cross.
//
// Dropping [[offset]] (T17) exposed a pre-existing wrong type-mapping that
// produced SILENT-WRONG std140 layout (compiles at exit 0, reads wrong data —
// undetectable without a Metal compiler). Each member type below was diffed
// against the spirv-cross --msl oracle (Step-0 truth table); these tests pin
// zioshade's emitted MSL type to EXACTLY what spirv-cross emits.
//
// std140 facts that drive the oracle's choices (all verified via spirv-dis):
//   * Matrices always carry MatrixStride 16 (each column is vec4-aligned).
//     spirv-cross emits float{cols}x{rows'} where a 2-row matrix is widened to
//     4 rows (float2x2's 8-byte columns would break std140); 3-row stays 3
//     (MSL float3 column is already 16-byte aligned). So:
//       mat2→float2x4  mat3→float3x3  mat4→float4x4
//       mat2x3→float2x3 mat2x4→float2x4
//       mat3x2→float3x4 mat3x4→float3x4
//       mat4x2→float4x4 mat4x3→float4x3
//   * std140 scalar/small-vector arrays carry ArrayStride 16, so the element is
//     widened to its 16-byte form: float→float4, int→int4, uint→uint4,
//     vec2→float4, vec3→float3 (already 16), vec4→float4. Matrix arrays reuse
//     the matrix rule (mat3[]→float3x3[], mat4[]→float4x4[]).
// ---------------------------------------------------------------------------

test "T18.1: mat2 member — float2x4 (col stride 16), NOT float2x2" {
    // ORACLE spirv-cross: struct U { float2x4 m; };
    // float2x2 (8-byte columns) is SILENT-WRONG std140 layout.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat2 m; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.m[0], u.m[1]); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float2x4 m;");
    try assertNotContains(msl, "float2x2");
    try assertNotContains(msl, "[[offset(");
}

test "T18.2: mat3 member — float3x3 (col stride 16), NOT packed_float3x3" {
    // ORACLE spirv-cross: struct U { float3x3 m; };
    // packed_float3x3 (12-byte columns) is SILENT-WRONG std140 layout.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat3 m; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.m[0], 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3x3 m;");
    try assertNotContains(msl, "packed_float3x3");
    try assertNotContains(msl, "[[offset(");
}

test "T18.3: mat4 member — float4x4 (already correct, regression guard)" {
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat4 m; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = u.m[0]; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4x4 m;");
    try assertNotContains(msl, "[[offset(");
}

test "T18.4: mat3x4 member — float3x4 (rows NOT dropped), NOT packed_float3x3" {
    // ORACLE spirv-cross: struct U { float3x4 m; };
    // packed_float3x3 drops the 4th row entirely — SILENT-WRONG (wrong TYPE).
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat3x4 m; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = u.m[0]; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3x4 m;");
    try assertNotContains(msl, "packed_float3x3");
    try assertNotContains(msl, "[[offset(");
}

test "T18.5: mat3x2 member — float3x4 (rows widened 2->4)" {
    // ORACLE spirv-cross: struct U { float3x4 m; };
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat3x2 m; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.m[0], u.m[1]); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3x4 m;");
    try assertNotContains(msl, "packed_float3x3");
    try assertNotContains(msl, "[[offset(");
}

test "T18.6: mat4x2 member — float4x4 (rows widened 2->4), NOT float4x2" {
    // ORACLE spirv-cross: struct U { float4x4 m; };
    // float4x2 (8-byte columns) is SILENT-WRONG std140 layout.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat4x2 m; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.m[0], u.m[1]); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4x4 m;");
    try assertNotContains(msl, "float4x2");
    try assertNotContains(msl, "[[offset(");
}

test "T18.7: mat2x3 member — float2x3 (3 rows kept, regression guard)" {
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat2x3 m; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.m[0], 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float2x3 m;");
    try assertNotContains(msl, "[[offset(");
}

test "T18.8: mat4x3 member — float4x3 (3 rows kept, regression guard)" {
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat4x3 m; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.m[0], 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4x3 m;");
    try assertNotContains(msl, "[[offset(");
}

test "T18.9: vec2 array — float4 a[3] (stride 16), NOT float2 a[3]" {
    // ORACLE spirv-cross: struct U { float4 a[3]; };
    // float2 a[3] (stride 8) is SILENT-WRONG std140 array layout.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec2 a[3]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a[0], u.a[1]); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4 a[3];");
    try assertNotContains(msl, "float2 a[3]");
    try assertNotContains(msl, "[[offset(");
}

test "T18.10: int array — int4 a[3] (stride 16), NOT float4/int a[3]" {
    // ORACLE spirv-cross: struct U { int4 a[3]; };
    // float4 a[3] is SILENT-WRONG (wrong element TYPE: int read as float).
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { int a[3]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(float(u.a[0]), float(u.a[1]), float(u.a[2]), 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "int4 a[3];");
    try assertNotContains(msl, "float4 a[3]");
    try assertNotContains(msl, "[[offset(");
}

test "T18.11: float array — float4 a[3] (already correct, regression guard)" {
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { float a[3]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a[0], u.a[1], u.a[2], 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4 a[3];");
    try assertNotContains(msl, "[[offset(");
}

test "T18.12: vec3 array — float3 a[3] (already correct, regression guard)" {
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec3 a[3]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a[0], 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3 a[3];");
    try assertNotContains(msl, "[[offset(");
}

test "T18.13: vec4 array — float4 a[3] (already correct, regression guard)" {
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec4 a[3]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = u.a[0] + u.a[1] + u.a[2]; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4 a[3];");
    try assertNotContains(msl, "[[offset(");
}

test "T18.14: uint array — uint4 a[3] (already correct, regression guard)" {
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { uint a[3]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(float(u.a[0]), float(u.a[1]), float(u.a[2]), 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "uint4 a[3];");
    try assertNotContains(msl, "[[offset(");
}

test "T18.15: mat3 array — float3x3 a[2], NOT packed_float3x3 a[2]" {
    // ORACLE spirv-cross: struct U { float3x3 a[2]; };
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat3 a[2]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a[0][0], 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3x3 a[2];");
    try assertNotContains(msl, "packed_float3x3");
    try assertNotContains(msl, "[[offset(");
}

test "T18.15b: ivec2 array — int4 a[3] (stride 16, int scalar widened)" {
    // ORACLE spirv-cross: struct U { int4 a[3]; };
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { ivec2 a[3]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(float(u.a[0].x), float(u.a[1].y), float(u.a[2].x), 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "int4 a[3];");
    try assertNotContains(msl, "int2 a[3]");
    try assertNotContains(msl, "[[offset(");
}

test "T18.15c: uvec3 array — uint3 a[2] (16-aligned, scalar kept uint)" {
    // ORACLE spirv-cross: struct U { uint3 a[2]; };
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { uvec3 a[2]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(float(u.a[0].x), float(u.a[1].z), 0.0, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "uint3 a[2];");
    try assertNotContains(msl, "[[offset(");
}

test "T18.16: mat4 array — float4x4 a[2] (already correct, regression guard)" {
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat4 a[2]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = u.a[0][0]; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4x4 a[2];");
    try assertNotContains(msl, "[[offset(");
}

// Following-member offset: a fixed-size matrix member must occupy its FULL
// std140 size so the next member lands at the std140 offset spirv-cross uses.
// Asserting the type SEQUENCE pins the layout (the offset is implied by the
// preceding member's MSL size matching std140).

test "T18.17: mat3 m; vec3 v; — float3x3 then float3 (v at std140 offset 48)" {
    // ORACLE spirv-cross: struct U { float3x3 m; float3 v; };
    // packed_float3x3 (36 B) would lay v at 36 — SILENT-WRONG (oracle: 48).
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat3 m; vec3 v; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.m[0] + u.v, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3x3 m;");
    try assertContains(msl, "float3 v;");
    try assertNotContains(msl, "packed_float3x3");
    try assertNotContains(msl, "[[offset(");
}

test "T18.18: mat2 m; vec4 v; — float2x4 then float4 (v at std140 offset 32)" {
    // ORACLE spirv-cross: struct U { float2x4 m; float4 v; };
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat2 m; vec4 v; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.m[0], u.m[1]) + u.v; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float2x4 m;");
    try assertContains(msl, "float4 v;");
    try assertNotContains(msl, "float2x2");
    try assertNotContains(msl, "[[offset(");
}

test "T18.19: vec2 a[2]; float b; — float4 a[2] then float b (b at std140 offset 32)" {
    // ORACLE spirv-cross: struct U { float4 a[2]; float b; };
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec2 a[2]; float b; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a[0], u.a[1]) * u.b; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4 a[2];");
    try assertContains(msl, "float b;");
    try assertNotContains(msl, "float2 a[2]");
    try assertNotContains(msl, "[[offset(");
}

test "T18.20: mat3x2 array — float3x4 a[2] (non-square, rows widened via MatrixStride)" {
    // ORACLE spirv-cross: struct U { float3x4 a[2]; };
    // Pins the stride-driven matrix-array element path (MatrixStride 16 in
    // std140 → rows widened 2->4). packed_float3x3 would drop rows + use the
    // wrong 12-byte column stride.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { mat3x2 a[2]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a[0][0], u.a[1][0]); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3x4 a[2];");
    try assertNotContains(msl, "packed_float3x3");
    try assertNotContains(msl, "[[offset(");
}

// ---------------------------------------------------------------------------
// T17: Depth/comparison sampler texture type (depth2d<float>, not
// texture2d<float>). A `sampler2DShadow` lowers to an OpTypeImage whose Depth
// field is 1; its MSL methods `.sample_compare` / `.gather_compare` are members
// of `depth2d<float>`, NOT `texture2d<float>`. Emitting `texture2d<float>` for
// such a sampler produces MSL that does not compile (silent-wrong cross-compile).
//
// Scope: only the 2D depth case (Dim==2D) is modelled — this whole backend
// hardcodes 2D textures, so a non-2D depth sampler (samplerCubeShadow etc.) is
// deliberately NOT promoted to depth2d (that would be a different mis-type, see
// T17.4); it stays on the pre-existing texture2d path until non-2D textures are
// supported backend-wide.
//
// Oracle (spirv-cross 1.4.341.1) for `textureGather(sampler2DShadow, uv, ref)`:
//   fragment main0_out main0(main0_in in [[stage_in]],
//       depth2d<float> shadowTex [[texture(0)]], sampler shadowTexSmplr [[sampler(0)]])
//   { ... shadowTex.gather_compare(shadowTexSmplr, in.vUV, in.vRef); ... }
// and for `texture(sampler2DShadow, vec3(uv, ref))` the same `depth2d<float>`
// with `.sample_compare`.
// ---------------------------------------------------------------------------

test "T17.1: sampler2DShadow + textureGather → depth2d<float> (gather_compare)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow shadowTex;
        \\layout(location=0) in vec2 vUV;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureGather(shadowTex, vUV, vRef); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The comparison sampler must be declared depth2d<float> (matches oracle).
    try assertContains(msl, "depth2d<float> shadowTex [[texture(0)]]");
    // No texture2d<float> may survive for this sampler anywhere (entry param,
    // impl param, …) — that would be non-compiling MSL.
    try assertNotContains(msl, "texture2d<float> shadowTex");
    // The gather_compare method itself is unchanged.
    try assertContains(msl, ".gather_compare(");
}

// #170/#470: textureProj on a shadow sampler (OpImageSampleProjDref). The op was
// missing from resultIdFromOp, so its result was never named and the output store
// defaulted to 0 -- a SILENT NO-OP shadow. And the projective divide reached the
// coordinate but not the Dref. Both must hold: sample_compare(s, uv/q, dref/q), with
// the result consumed. Matches the spirv-cross MSL oracle.
test "T17.1b: textureProj(sampler2DShadow) divides BOTH coord and Dref, result not discarded" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow shadowTex;
        \\layout(location=0) in vec4 projCoord;
        \\layout(location=0) out float o;
        \\void main(){ o = textureProj(shadowTex, projCoord); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, ".sample_compare(");
    // Both coordinate and Dref divided by the projective divisor.
    try std.testing.expect(std.mem.count(u8, msl, " / ") >= 2);
    // The compare result must be used, not silently replaced by 0.
    try assertNotContains(msl, "o = 0");
}

test "T17.2: sampler2DShadow + texture() compare → depth2d<float> (sample_compare)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow shadowTex;
        \\layout(location=0) in vec2 vUV;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowTex, vec3(vUV, vRef))); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "depth2d<float> shadowTex [[texture(0)]]");
    try assertNotContains(msl, "texture2d<float> shadowTex");
    try assertContains(msl, ".sample_compare(");
}

test "T17.3: plain sampler2D stays texture2d<float> (no depth2d regression)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) in vec2 vUV;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = texture(tex, vUV); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // A non-comparison sampler must remain texture2d<float>.
    try assertContains(msl, "texture2d<float> tex");
    try assertNotContains(msl, "depth2d");
}

test "T17.4: samplerCubeShadow is NOT promoted to depth2d (2D-scoped)" {
    // zioshade marks ALL shadow samplers (2D/Cube/Array) with OpTypeImage Depth=1,
    // but only the 2D form maps to MSL `depth2d<float>`; a cube shadow's correct
    // type is `depthcube<float>`. Since this backend has no non-2D texture support
    // (every texture is hardcoded 2D), mis-typing a cube shadow as `depth2d` would
    // just trade one non-compiling type for another. The depth promotion is gated
    // on Dim==2D, so a samplerCubeShadow must NOT acquire a depth2d type; it stays
    // on the pre-existing (separately-tracked) non-2D path.
    const source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeShadow shadowCube;
        \\layout(location=0) in vec3 vDir;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowCube, vec4(vDir, vRef))); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The 2D-only depth promotion must not mis-fire on a cube shadow sampler.
    try assertNotContains(msl, "depth2d");
}

test "T18.21: std140 float array element — body indexes + narrows widened element (oracle u.arr[0].x)" {
    // ORACLE spirv-cross: struct U { float4 arr[4]; float4 tail; }; ... u.arr[0].x
    // std140 widens the scalar element to `float4 arr[4]`, so the body must index
    // the array AND narrow back with `.x`, never the leftover synthesized member
    // access `arr._m0`.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { float arr[4]; vec4 tail; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.arr[0]) + u.tail; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4 arr[4]");
    try assertContains(msl, "u_1.arr[0].x");
    try assertNotContains(msl, "arr._m0");
}

test "T18.22: std140 vec3 array element — float3 a[N], body indexes WITHOUT a swizzle" {
    // ORACLE spirv-cross: struct U { float3 a[3]; float4 tail; }; ... u.a[0]
    // A vec3 array element is NOT widened to float4 (float3 already fills a
    // 16-byte slot), so the decl stays `float3 a[3]` and the body accesses it
    // BARE — appending a `.xyz` would diverge from spirv-cross.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec3 a[3]; vec4 tail; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a[0], 1.0) + u.tail; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3 a[3];");
    try assertContains(msl, "u_1.a[0]");
    try assertNotContains(msl, "u_1.a[0].xyz");
    try assertNotContains(msl, "a._m0");
}

test "T18.23: std140 vec2 array element — float4 a[N], body narrows with .xy (oracle u.a[0].xy)" {
    // ORACLE spirv-cross: struct U { float4 a[3]; }; ... u.a[0].xy
    // std140 widens a vec2 element to float4, so the body indexes AND narrows
    // back to the 2 live components with `.xy`.
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform U { vec2 a[3]; } u;
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(u.a[0], 0.0, 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4 a[3];");
    try assertContains(msl, "u_1.a[0].xy");
    try assertNotContains(msl, "a._m0");
}

test "T18.24: byte-identical UBO blocks keep distinct member names" {
    // ORACLE spirv-cross --msl: struct A { float4 ca; }; struct B { float4 cb; };
    // and body `... = u.ca + ...; ... = u_1.cb`. Two uniform blocks with
    // byte-identical layouts (both `{ vec4 }`) but DIFFERENT member names must
    // NOT be merged by the struct-dedup pass: dedup keyed only on member types
    // aliased B's member onto A's, so b's struct declared `float4 ca` and the
    // body emitted `b_1.ca` instead of `b_1.cb`.
    // (Renumbered from T18.21 -> T18.24 on merge: origin/main's PR #27 claimed
    //  the T18.21-23 labels for the std140 array-element tests above.)
    const source =
        \\#version 450
        \\layout(binding=0,std140) uniform A { vec4 ca; } a;
        \\layout(binding=1,std140) uniform B { vec4 cb; } b;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.ca + b.cb; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Each block keeps its own source member name in its struct decl.
    try assertContains(msl, "float4 ca;");
    try assertContains(msl, "float4 cb;");
    // Body access expressions reference the correct, distinct members.
    try assertContains(msl, "a_1.ca");
    try assertContains(msl, "b_1.cb");
    // The collision aliased b's member onto a's — `b_1.ca` must never appear.
    try assertNotContains(msl, "b_1.ca");
}

test "T18.22: row_major UBO matrix access must be transposed (vs column_major)" {
    // ORACLE spirv-cross --msl, `mat4 m` with `o = a.m[0]`:
    //   row_major    → out.o = float4(a.m[0][0], a.m[1][0], a.m[2][0], a.m[3][0]);
    //   column_major → out.o = a.m[0];
    // The RowMajor decoration means the matrix is stored transposed, so reading
    // logical column 0 must GATHER element 0 from every stored column. zioshade
    // currently ignores the RowMajor decoration and emits the SAME `a_1.m._m0`
    // for both qualifiers — reading row-major storage as column-major
    // (silent-wrong output). See codegen RowMajor/MatrixStride fix on
    // claude/funny-murdock-8da7d8; the MSL backend never consumes that decoration.
    const row_src =
        \\#version 450
        \\layout(binding=0,std140,row_major) uniform A { mat4 m; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[0]; }
    ;
    const col_src =
        \\#version 450
        \\layout(binding=0,std140,column_major) uniform A { mat4 m; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[0]; }
    ;
    const row_msl = try compileToMsl(row_src);
    defer alloc.free(row_msl);
    const col_msl = try compileToMsl(col_src);
    defer alloc.free(col_msl);

    // (1) Core bug: a row_major block and a column_major block that differ ONLY
    // in layout qualifier must NOT produce byte-identical MSL.
    if (std.mem.eql(u8, row_msl, col_msl)) {
        std.debug.print(
            "row_major and column_major MSL are byte-identical (silent-wrong):\n{s}\n",
            .{row_msl},
        );
        return error.TestUnexpectedFind;
    }

    // (2) Oracle behaviour: reading logical column 0 of a row_major matrix must
    // read the LOGICAL matrix, which (given column-major storage of the
    // transpose) means an explicit transpose(). Assert the exact emitted form.
    try assertContains(row_msl, "transpose(a_1.m)[0]");
    // The column_major (correct-as-is) path must NOT gain a transpose.
    try assertNotContains(col_msl, "transpose(");
}

test "T18.23: non-square row_major matrix is an honest error (not silent-wrong)" {
    // A row_major NON-square matrix (e.g. mat3x4) must be stored with SWAPPED
    // member dimensions in MSL (the transpose's shape, float4x3), which is not
    // yet implemented. Until it is, the backend must FAIL LOUDLY instead of
    // declaring a column-major-shaped member with untransposed access —
    // i.e. silent-wrong output. Square row_major matrices (mat2/mat3/mat4)
    // ARE fully handled via transpose(); see T18.22.
    const source =
        \\#version 450
        \\layout(binding=0,std140,row_major) uniform A { mat3x4 m; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[0]; }
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    if (zioshade.spirvToMSL(alloc, spirv, .{})) |msl| {
        defer alloc.free(msl);
        std.debug.print(
            "expected an honest error for non-square row_major matrix, got MSL:\n{s}\n",
            .{msl},
        );
        return error.TestExpectedError;
    } else |_| {
        // Expected: an honest error rather than silent-wrong output.
    }
}

test "T18.24: row_major SQUARE matrix ARRAY read is transposed" {
    // The RowMajor decoration sits on the struct MEMBER even when that member is
    // an array of matrices. Reading `a.m[1][0]` must transpose the indexed
    // element: ORACLE spirv-cross --msl emits
    //   float4(a.m[1][0][0], a.m[1][1][0], a.m[1][2][0], a.m[1][3][0])
    // i.e. transpose(a.m[1])[0]. Without array handling zioshade emitted the
    // untransposed `a_1.m[1]._m0` (silent-wrong).
    const source =
        \\#version 450
        \\layout(binding=0,std140,row_major) uniform A { mat4 m[2]; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[1][0]; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "transpose(a_1.m[1])[0]");
    try assertNotContains(msl, "a_1.m[1]._m0");
}

test "T18.25: non-square row_major matrix in a NESTED struct is an honest error" {
    // The non-square honest-error must also cover matrices inside nested
    // structs (emitted through a shared forward-decl path that bypasses the
    // top-level member emitter). `Inner { mat3x4 m; }` in a row_major block must
    // FAIL LOUDLY, not emit a column-major-shaped `float3x4` member.
    const source =
        \\#version 450
        \\struct Inner { mat3x4 m; };
        \\layout(binding=0,std140,row_major) uniform A { Inner inner; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.inner.m[0]; }
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    if (zioshade.spirvToMSL(alloc, spirv, .{})) |msl| {
        defer alloc.free(msl);
        std.debug.print(
            "expected an honest error for nested non-square row_major matrix, got MSL:\n{s}\n",
            .{msl},
        );
        return error.TestExpectedError;
    } else |_| {}
}

test "T18.26: storing through a row_major matrix is an honest error (not silent-wrong)" {
    // A row_major matrix is stored transposed; a WRITE to a logical column would
    // need a transposed scatter, which we cannot express as `transpose(...) = x`.
    // Rather than emit a plain (wrong-location) store, fail loudly.
    const source =
        \\#version 450
        \\layout(binding=0,std430,row_major) buffer B { mat4 m; } b;
        \\layout(location=0) out vec4 o;
        \\void main() { b.m[0] = vec4(1.0); o = vec4(0.0); }
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    if (zioshade.spirvToMSL(alloc, spirv, .{})) |msl| {
        defer alloc.free(msl);
        std.debug.print(
            "expected an honest error for a row_major matrix store, got MSL:\n{s}\n",
            .{msl},
        );
        return error.TestExpectedError;
    } else |_| {}
}

// ---------------------------------------------------------------------------
// Image-query 3-component (ivec3) coverage — regression guard for the rank
// mismatch where the backend splatted get_width() into all components and
// never read height/depth/array-size for an int3 result.
// ---------------------------------------------------------------------------

test "msl: imageSize(image2DArray) emits get_array_size for the 3rd component" {
    const source =
        \\#version 450
        \\layout(rgba8, binding = 0) uniform image2DArray img;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec3 s = imageSize(img);
        \\    o = vec4(float(s.x), float(s.y), float(s.z), 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "get_width");
    try assertContains(msl, "get_height");
    try assertContains(msl, "get_array_size");
    try assertContains(msl, "int3");
}

test "msl: imageSize(image3D) emits get_depth for the 3rd component" {
    const source =
        \\#version 450
        \\layout(rgba8, binding = 0) uniform image3D img;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec3 s = imageSize(img);
        \\    o = vec4(float(s.x), float(s.y), float(s.z), 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "get_width");
    try assertContains(msl, "get_height");
    try assertContains(msl, "get_depth");
    try assertContains(msl, "int3");
}

test "msl: imageSize(imageCubeArray) emits get_array_size for the 3rd component" {
    const source =
        \\#version 450
        \\layout(rgba8, binding = 0) uniform imageCubeArray img;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec3 s = imageSize(img);
        \\    o = vec4(float(s.x), float(s.y), float(s.z), 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "get_array_size");
    try assertContains(msl, "int3");
}

// ---------------------------------------------------------------------------
// Vertex input built-ins (gl_VertexIndex / gl_InstanceIndex) — must be threaded
// as MSL entry-point attributes, NOT leaked as bare undeclared identifiers
// (which is uncompilable MSL — silent-wrong). Mirrors spirv-cross --msl.
// ---------------------------------------------------------------------------

test "msl: gl_VertexIndex / gl_InstanceIndex thread as [[vertex_id]]/[[instance_id]]" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 col;
        \\void main() {
        \\    gl_Position = vec4(float(gl_VertexIndex), float(gl_InstanceIndex), 0.0, 1.0);
        \\    col = vec4(1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    // Entry-point parameters carry the MSL builtin attribute + uint type.
    try assertContains(msl, "uint gl_VertexIndex [[vertex_id]]");
    try assertContains(msl, "uint gl_InstanceIndex [[instance_id]]");
    // Forwarded to the helper as a signed int (the SPIR-V variable is int).
    try assertContains(msl, "int(gl_VertexIndex)");
    try assertContains(msl, "int(gl_InstanceIndex)");
    // The helper declares them as signed int params.
    try assertContains(msl, "int gl_VertexIndex");
}

test "msl: gl_FrontFacing threads as bool [[front_facing]]" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    o = gl_FrontFacing ? vec4(1.0,0.0,0.0,1.0) : vec4(0.0,1.0,0.0,1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    // Entry-point parameter carries the MSL builtin attribute + bool type.
    try assertContains(msl, "bool gl_FrontFacing [[front_facing]]");
    // Threaded into the helper as a bool (no int cast — it is already bool).
    try assertContains(msl, "bool gl_FrontFacing)");
    try assertNotContains(msl, "int(gl_FrontFacing)");
}

test "msl: gl_PointSize becomes a [[point_size]] main0_out field" {
    const source =
        \\#version 450
        \\void main() {
        \\    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
        \\    gl_PointSize = 4.0;
        \\}
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    // gl_PointSize is a struct field with the MSL builtin attribute, not a leak.
    try assertContains(msl, "float gl_PointSize [[point_size]]");
    // Body store resolves through the output struct.
    try assertContains(msl, "out.gl_PointSize = 4.0");
}

test "msl: compute built-ins thread as kernel parameter attributes" {
    const source =
        \\#version 450
        \\layout(local_size_x=8) in;
        \\layout(std430, binding=0) buffer B { uint data[]; };
        \\void main() {
        \\    data[gl_GlobalInvocationID.x] =
        \\        gl_LocalInvocationID.x + gl_WorkGroupID.x + gl_LocalInvocationIndex;
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "uint3 gl_GlobalInvocationID [[thread_position_in_grid]]");
    try assertContains(msl, "uint3 gl_LocalInvocationID [[thread_position_in_threadgroup]]");
    try assertContains(msl, "uint3 gl_WorkGroupID [[threadgroup_position_in_grid]]");
    try assertContains(msl, "uint gl_LocalInvocationIndex [[thread_index_in_threadgroup]]");
}

test "msl: descriptor remap overrides [[buffer]]/[[texture]]/[[sampler]] slots" {
    // G6: per-resource (set, binding) -> MSL slot override. UBO at binding 0 and
    // sampler2D at binding 1 are remapped to buffer(4) and texture(2)/sampler(2).
    const source =
        \\#version 450
        \\layout(set = 0, binding = 0) uniform U { vec4 tint; } u;
        \\layout(set = 0, binding = 1) uniform sampler2D tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = texture(tex, uv) * u.tint; }
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{
        .resource_bindings = &.{
            .{ .set = 0, .binding = 0, .msl_slot = 4 },
            .{ .set = 0, .binding = 1, .msl_slot = 2 },
        },
    });
    defer alloc.free(msl);
    try assertContains(msl, "[[buffer(4)]]");
    try assertContains(msl, "[[texture(2)]]");
    try assertContains(msl, "[[sampler(2)]]");
}

fn stripMerge(a: std.mem.Allocator, spirv: []const u32) ![]u32 {
    var out = try std.ArrayList(u32).initCapacity(a, spirv.len);
    errdefer out.deinit(a);
    try out.appendSlice(a, spirv[0..5]);
    var i: usize = 5;
    while (i < spirv.len) {
        const wc: usize = spirv[i] >> 16;
        const op: u32 = spirv[i] & 0xFFFF;
        if (wc == 0 or i + wc > spirv.len) break;
        if (op != 247 and op != 246) try out.appendSlice(a, spirv[i .. i + wc]);
        i += wc;
    }
    return out.toOwnedSlice(a);
}

test "msl: unstructured switch (stripped OpSelectionMerge) is recovered (G2)" {
    // G2: CFG structurization recovers the stripped merge so the switch compiles
    // faithfully — output identical to the structured original (default kept).
    const source =
        \\#version 450
        \\layout(location = 0) flat in int sel;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 c = vec4(0.0);
        \\    switch (sel) { case 0: c = vec4(1.0); break; case 1: c = vec4(0.5); break; default: c = vec4(0.2); break; }
        \\    o = c;
        \\}
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const ok = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(ok);
    const stripped = try stripMerge(alloc, spirv);
    defer alloc.free(stripped);
    const recovered = try zioshade.spirvToMSL(alloc, stripped, .{});
    defer alloc.free(recovered);
    try std.testing.expectEqualStrings(ok, recovered);
}

// ---------------------------------------------------------------------------
// Array constant declaration (no undeclared-identifier silent-wrong)
//
// An array `OpConstantComposite` (a function-local `const T a[N]` or a
// module-scope `const T a[N]` lowered to a Private OpVariable with a constant
// initializer) must be emitted as a module-scope Metal constant
// (`constant T name[N] = {…};`) so a runtime index `a[i]` resolves to a
// DECLARED identifier. The previous backend referenced the array composite /
// Private var by an undeclared name (`a[i]` → `vN[i]` with no `vN` anywhere,
// or a local `T v[N]; v = vC;` array-copy of an undeclared `vC`) — both are
// silent-wrong: zioshade exits 0 but the MSL does not compile in Metal.
//
// Oracle: spirv-cross --msl promotes both to module scope as
// `constant spvUnsafeArray<T,N> _k = …;` indexed `_k[i]`.
// ---------------------------------------------------------------------------

/// Verify the MSL declares a module-scope `constant T name[…] = {…};` array and
/// that `name` is indexed somewhere after the declaration (i.e. the runtime
/// index resolves to the declared constant, not an undeclared identifier).
fn assertConstArrayDeclaredAndIndexed(msl: []const u8) !void {
    const decl_kw = "constant ";
    const start = std.mem.indexOf(u8, msl, decl_kw) orelse {
        std.debug.print("No module-scope `constant` array declaration in:\n{s}\n", .{msl});
        return error.NoConstantDecl;
    };
    const bracket = std.mem.indexOfPos(u8, msl, start, "[") orelse return error.NoArrayDecl;
    // The declared name is the token immediately before the `[`.
    var ns = bracket;
    while (ns > start and msl[ns - 1] != ' ') ns -= 1;
    const name = msl[ns..bracket];
    if (name.len == 0) return error.EmptyConstName;
    const decl_end = std.mem.indexOfPos(u8, msl, bracket, "= {") orelse {
        std.debug.print("`constant` array declaration is not brace-initialized in:\n{s}\n", .{msl});
        return error.ConstNotBraceInitialized;
    };
    const idx_pat = try std.fmt.allocPrint(alloc, "{s}[", .{name});
    defer alloc.free(idx_pat);
    if (std.mem.indexOfPos(u8, msl, decl_end, idx_pat) == null) {
        std.debug.print("Declared constant `{s}` is never indexed in:\n{s}\n", .{ name, msl });
        return error.ConstNotIndexed;
    }
}

test "msl: function-local const array indexed at runtime is declared (no undeclared identifier)" {
    // `int(gl_FragCoord.x) & 3` avoids the orthogonal integer-`flat`-input rule.
    const source =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out float FragColor;
        \\void main()
        \\{
        \\    const float lut[4] = float[](10.0, 20.0, 30.0, 40.0);
        \\    int i = int(gl_FragCoord.x) & 3;
        \\    FragColor = lut[i];
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "10.0, 20.0, 30.0, 40.0");
    try assertConstArrayDeclaredAndIndexed(msl);
}

test "msl: module-scope const array indexed at runtime is declared (no undeclared identifier)" {
    const source =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out float FragColor;
        \\const float LUT[4] = float[](10.0, 20.0, 30.0, 40.0);
        \\void main()
        \\{
        \\    int i = int(gl_FragCoord.x) & 3;
        \\    FragColor = LUT[i];
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "10.0, 20.0, 30.0, 40.0");
    try assertConstArrayDeclaredAndIndexed(msl);
}

test "msl: mutated local array initialized from a constant is brace-initialized (not array-copied)" {
    // A local array that is partially written cannot be promoted to a module
    // constant; the constant initializer is folded into the declaration as a
    // brace initializer (`T a[N] = {…};`) so it remains a mutable local without
    // an invalid C-array copy (`a = vC;`).
    const source =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out float FragColor;
        \\void main()
        \\{
        \\    vec4 foo[4] = vec4[](vec4(0.0), vec4(1.0), vec4(8.0), vec4(5.0));
        \\    int i = int(gl_FragCoord.x) & 3;
        \\    if (i > 2) foo[1].z = 20.0;
        \\    FragColor = foo[i].z;
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Declaration is brace-initialized in place (`T a[4] = {…};`) …
    try assertContains(msl, "[4] = {");
    // … not a bare uninitialized array decl (`T a[4];`) followed by an invalid
    // whole-array copy assignment (`a = vC;`), which is the pre-fix silent-wrong.
    try assertNotContains(msl, "[4];");
}

test "msl: local array partially written via an unmerged nested chain is NOT promoted (write not dropped)" {
    // A whole-element read (`tmp = foo[i]`) makes the `foo[i]` access chain have a
    // non-AccessChain (Load) user, so the optimizer does NOT flatten the nested
    // chain of the member write `foo[i].z = …` (it stays a two-level chain rooted
    // at the intermediate `foo[i]` chain, not directly at `foo`). The mutation
    // analysis must still see this as a partial write and keep `foo` a mutable
    // local — promoting it to a read-only `constant` would silently drop the
    // store (and write to the `constant` address space).
    const source =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out float FragColor;
        \\void main()
        \\{
        \\    vec4 foo[4] = vec4[](vec4(0.0), vec4(1.0), vec4(8.0), vec4(5.0));
        \\    int i = int(gl_FragCoord.x) & 3;
        \\    vec4 tmp = foo[i];
        \\    foo[i].z = 20.0;
        \\    FragColor = tmp.x + foo[i].z;
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The partial write survives …
    try assertContains(msl, "= 20.0");
    // … and `foo` is NOT promoted to a module-scope read-only constant.
    try assertNotContains(msl, "constant float4");
}

/// Assert the MSL emits the `spvUnsafeArray<T, Num>` template helper EXACTLY
/// once (a duplicate definition would not compile in Metal).
fn assertSpvUnsafeArrayTemplateOnce(msl: []const u8) !void {
    const pat = "struct spvUnsafeArray";
    const first = std.mem.indexOf(u8, msl, pat) orelse {
        std.debug.print("No `struct spvUnsafeArray` template in output:\n{s}\n", .{msl});
        return error.NoSpvUnsafeArrayTemplate;
    };
    if (std.mem.indexOfPos(u8, msl, first + pat.len, pat) != null) {
        std.debug.print("`struct spvUnsafeArray` emitted more than once in:\n{s}\n", .{msl});
        return error.SpvUnsafeArrayTemplateDuplicated;
    }
}

test "msl: whole-array value copy from a const global uses spvUnsafeArray (no illegal C-array copy)" {
    // `float local[4] = LUT;` is a whole-array VALUE copy. Metal C-arrays are not
    // assignable, so the array VALUE type must be `spvUnsafeArray<float, 4>` (the
    // spirv-cross idiom). The pre-fix silent-wrong was:
    //   float v14 = v3;   // INVALID scalar-from-array load
    //   v13 = v14;        // INVALID C-array whole-copy
    const source =
        \\#version 450
        \\layout(location=0) out float FragColor;
        \\const float LUT[4] = float[](1.0,2.0,3.0,4.0);
        \\void main(){ float local[4] = LUT; int i = int(gl_FragCoord.x) & 3; FragColor = local[i]; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The array value type is spvUnsafeArray<float, 4>, used for the local copy.
    try assertContains(msl, "spvUnsafeArray<float, 4>");
    // The template helper is emitted exactly once.
    try assertSpvUnsafeArrayTemplateOnce(msl);
    // No illegal scalar-from-array load (`float vN = vM;` where vM is the array)
    // and no bare `float vN[4];` decl followed by a whole-array copy assignment.
    try assertNotContains(msl, "float v14 = v");
}

test "msl: value-copied const global is materialized as a spvUnsafeArray (matching the copy types)" {
    // The SOURCE of a whole-array copy — the read-only const global — must also be
    // spelled `constant spvUnsafeArray<…>` (not the plain `constant T[N]` C-array),
    // otherwise the copy `local = global;` is a type mismatch / illegal C-array
    // copy. This mirrors `spirv-cross --msl`'s materialization of the global.
    const source =
        \\#version 450
        \\layout(location=0) out float FragColor;
        \\const float LUT[4] = float[](1.0,2.0,3.0,4.0);
        \\void main(){ float local[4] = LUT; int i = int(gl_FragCoord.x) & 3; FragColor = local[i]; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The const global itself is a `constant spvUnsafeArray<float, 4>`, built via
    // the template's brace-init constructor (legal copy source).
    try assertContains(msl, "constant spvUnsafeArray<float, 4>");
    try assertContains(msl, "spvUnsafeArray<float, 4>({ 1.0, 2.0, 3.0, 4.0 })");
    // The whole-array C-array decl `float vN[4];` must be gone (replaced by the
    // template-typed local), so no illegal C-array copy can occur.
    try assertNotContains(msl, "[4];");
}

test "msl: read-only const array (no value copy) still uses the plain `constant T[N]` path" {
    // Regression guard: when a const array is ONLY indexed (never whole-copied),
    // keep the simpler valid-Metal `constant T name[N] = {…};` path and do NOT
    // pull in the spvUnsafeArray template (intentional divergence from spirv-cross).
    const source =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out float FragColor;
        \\const float LUT[4] = float[](10.0, 20.0, 30.0, 40.0);
        \\void main()
        \\{
        \\    int i = int(gl_FragCoord.x) & 3;
        \\    FragColor = LUT[i];
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "10.0, 20.0, 30.0, 40.0");
    try assertConstArrayDeclaredAndIndexed(msl);
    try assertNotContains(msl, "spvUnsafeArray");
}

test "msl: local-to-local whole-array copy spells BOTH source and dest as spvUnsafeArray" {
    // A1: `float a[3]=…; a[0]=seed; float b[3]=a;` is a whole-array VALUE copy
    // between two Function-storage locals. The pre-fix silent-wrong left the
    // SOURCE local as a C-array:
    //   float v13[3] = {…};                 // C-array source
    //   spvUnsafeArray<float,3> v17 = v13;  // INVALID: no ctor from float[3]
    // spirv-cross declares BOTH ends spvUnsafeArray, so the copy is a legal
    // struct assignment. The source local must be spvUnsafeArray too.
    const source =
        \\#version 450
        \\layout(location=0) out float FragColor;
        \\layout(location=1) in float seed;
        \\void main(){
        \\  float a[3] = float[](1.0, 2.0, 3.0);
        \\  a[0] = seed;
        \\  float b[3] = a;
        \\  int i = int(gl_FragCoord.x) % 3;
        \\  FragColor = b[i];
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertSpvUnsafeArrayTemplateOnce(msl);
    // The mutable source local must be spvUnsafeArray (not a C-array). No
    // `float vN[3]` C-array declaration may survive for a value-copy source.
    try assertContains(msl, "spvUnsafeArray<float, 3>");
    try assertNotContains(msl, "float v13[3]");
    // Generalize: no `[3]` C-array suffix anywhere (both ends are template-typed).
    try assertNotContains(msl, "[3] = ");
    try assertNotContains(msl, "[3];");
}

test "msl: whole-array ternary/OpSelect result is spvUnsafeArray (no scalar-from-array select)" {
    // A2: `float la[4] = (t>0.5) ? A : B;` lowers to an OpSelect whose result
    // type is an ARRAY. The pre-fix silent-wrong typed it with mslType (drops
    // `[N]`) → an illegal scalar Select, and stored it into a C-array dest:
    //   float v16[4];                         // C-array dest
    //   float v21 = (v18) ? v19 : v20;        // INVALID scalar from float[4]
    //   v16 = v21;                            // INVALID C-array copy
    // spirv-cross spells the Select result `spvUnsafeArray<float, 4>`.
    const source =
        \\#version 450
        \\layout(location=0) out float FragColor;
        \\layout(location=1) in float t;
        \\const float A[4] = float[](1.0,2.0,3.0,4.0);
        \\const float B[4] = float[](5.0,6.0,7.0,8.0);
        \\void main(){
        \\  float la[4] = (t > 0.5) ? A : B;
        \\  int i = int(gl_FragCoord.x) & 3;
        \\  FragColor = la[i];
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertSpvUnsafeArrayTemplateOnce(msl);
    // The Select result and its dest must both be spvUnsafeArray, never a C-array.
    try assertContains(msl, "spvUnsafeArray<float, 4>");
    // No illegal scalar Select from array operands and no `[4]` C-array decls.
    try assertNotContains(msl, "float v16[4]");
    try assertNotContains(msl, "[4];");
    try assertNotContains(msl, "[4] = ");
    // The ternary still appears (lowering preserved), now array-typed.
    try assertContains(msl, " ? ");
}

test "msl: whole-array value copy of a SPEC-CONSTANT-sized array is an honest error (no silent [1] sizing)" {
    // B5: `mslValueType` needs a concrete compile-time `Num` for
    // `spvUnsafeArray<T, Num>`. A spec-constant array length (`OpSpecConstant`)
    // has no literal it can read; the pre-fix blindly used `words[3]` with an
    // `else 1` fallback, which would silently size the copy as `<float, 1>`
    // (dropping elements — silent-wrong). It must fail loud instead.
    const source =
        \\#version 450
        \\layout(constant_id=0) const int N = 4;
        \\layout(location=0) out float FragColor;
        \\layout(location=1) in float seed;
        \\void main(){
        \\  float a[N];
        \\  for (int k=0;k<N;k++) a[k]=seed+float(k);
        \\  float b[N] = a;
        \\  int i = int(gl_FragCoord.x) % N;
        \\  FragColor = b[i];
        \\}
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(
        error.UnresolvableArrayLength,
        zioshade.spirvToMSL(alloc, spirv, .{}),
    );
}

test "msl: array OpCompositeConstruct emits a spvUnsafeArray brace-init (no bogus scalar ctor)" {
    // C6: `float arr[3] = float[](a, b, c);` lowers to an OpCompositeConstruct
    // of array type. The pre-fix silent-wrong was a bogus scalar ctor + C-array
    // copy:
    //   float v12[3];
    //   float v16 = float(in.a, in.b, in.c);  // INVALID: scalar from 3 args
    //   v12 = v16;                            // INVALID C-array copy
    // spirv-cross spells it `spvUnsafeArray<float, 3>({ a, b, c })`.
    const source =
        \\#version 450
        \\layout(location=0) out float FragColor;
        \\layout(location=1) in float a;
        \\layout(location=2) in float b;
        \\layout(location=3) in float c;
        \\void main(){
        \\  float arr[3] = float[](a, b, c);
        \\  int i = int(gl_FragCoord.x) % 3;
        \\  FragColor = arr[i];
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertSpvUnsafeArrayTemplateOnce(msl);
    // The construct is a spvUnsafeArray brace-init over the three element values.
    try assertContains(msl, "spvUnsafeArray<float, 3>({ in.a, in.b, in.c })");
    // No bogus scalar ctor and no C-array decl/copy.
    try assertNotContains(msl, "float v16 = float(in.a");
    try assertNotContains(msl, "[3];");
}

test "msl: struct-element const-array value copy declares `struct S` before it is referenced" {
    // C7: `const S LUT[2]; S local[2] = LUT;` materializes the const global as
    // `constant spvUnsafeArray<S, 2> = …`. The pre-fix silent-wrong emitted that
    // const BEFORE `struct S` was declared (use-before-definition → uncompilable
    // Metal). The struct declaration must precede every reference to it.
    const source =
        \\#version 450
        \\layout(location=0) out vec4 FragColor;
        \\layout(location=1) in float seed;
        \\struct S { float a; float b; };
        \\const S LUT[2] = S[](S(1.0,2.0), S(3.0,4.0));
        \\void main(){
        \\  S local[2] = LUT;
        \\  local[0].a = seed;
        \\  int i = int(gl_FragCoord.x) & 1;
        \\  FragColor = vec4(local[i].a, local[i].b, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertSpvUnsafeArrayTemplateOnce(msl);
    // Both the struct decl and the const global appear.
    const struct_decl = "struct S\n";
    const const_use = "constant spvUnsafeArray<S, 2>";
    const sd = std.mem.indexOf(u8, msl, struct_decl) orelse {
        std.debug.print("No `struct S` declaration in output:\n{s}\n", .{msl});
        return error.NoStructDecl;
    };
    const cu = std.mem.indexOf(u8, msl, const_use) orelse {
        std.debug.print("No `constant spvUnsafeArray<S, 2>` in output:\n{s}\n", .{msl});
        return error.NoConstUse;
    };
    // The struct must be declared BEFORE it is referenced (no use-before-def).
    if (sd >= cu) {
        std.debug.print("`struct S` (at {d}) declared AFTER its use (at {d}):\n{s}\n", .{ sd, cu, msl });
        return error.StructUsedBeforeDeclared;
    }
}

test "msl: matrix-element const-array global folds and is declared with an initializer (#173 item1)" {
    // #173 item1: `const mat4 M[2] = …;` indexed at runtime. The FRONTEND now
    // folds the matrix constructors AND the array constructor to an
    // OpConstantComposite, so the Private `M` carries an initializer_id. The MSL
    // backend materializes it at module scope as
    // `constant float4x4 M[2] = {…};` (no longer the honest-error
    // `UndeclaredPrivateArrayGlobal`, no longer a silent-wrong undefined ident).
    const source =
        \\#version 450
        \\layout(location=0) out vec4 FragColor;
        \\const mat4 M[2] = mat4[](mat4(1.0), mat4(2.0));
        \\void main(){
        \\  int i = int(gl_FragCoord.x) & 1;
        \\  FragColor = M[i] * vec4(1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The array global is declared at module scope as a `constant float4x4[2]`
    // with a brace initializer (spirv-cross-style; the SSA name may differ from
    // the GLSL `M`). Pre-fix this was the honest-error UndeclaredPrivateArrayGlobal.
    try assertContains(msl, "constant float4x4 ");
    try assertContains(msl, "[2] = {");
    // The nested matrix constituents are INLINED as `float4x4(float4(…), …)` — not
    // referenced by an undefined name (the bug this fix closes). The diagonal
    // values 1.0 and 2.0 are materialized.
    try assertContains(msl, "float4x4(float4(1.0, 0.0, 0.0, 0.0)");
    try assertContains(msl, "float4x4(float4(2.0, 0.0, 0.0, 0.0)");
}

// ---------------------------------------------------------------------------
// T19: arrayed sampler/texture type names + sample-call layer split (#187).
//
// The OpTypeImage `Arrayed` operand (word[5]) was dropped when naming sampled
// textures, so every arrayed sampler degraded to the non-array 2D type and the
// array layer stayed glued into the sample coordinate. MSL puts the array layer
// in a SEPARATE argument, so both the type name AND the sample call were wrong.
//
// Oracle (spirv-cross --msl 1.4.341.1):
//   sampler2DArray       → texture2d_array<float>;   tex.sample(s, c.xy, uint(rint(c.z)))
//   samplerCubeArray     → texturecube_array<float>; tex.sample(s, c.xyz, uint(rint(c.w)))
//   sampler2DArrayShadow → depth2d_array<float>;     tex.sample_compare(s, c.xy, uint(rint(c.z)), c.w)
// Non-array samplers are unchanged (texture2d<float>, texturecube<float>, …).
// ---------------------------------------------------------------------------

test "T19.1: sampler2DArray → texture2d_array<float> + layer-split sample" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray tex;
        \\layout(location=0) in vec3 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = texture(tex, uv); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d_array<float> tex");
    // The 2D array layer is a separate argument: coord.xy + uint(rint(coord.z)).
    try assertContains(msl, ".sample(");
    try assertContains(msl, "uint(rint(");
    try assertContains(msl, ".xy, uint(rint(");
    try assertContains(msl, ".z))");
}

test "T19.2: samplerCubeArray → texturecube_array<float> + layer-split sample" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeArray tex;
        \\layout(location=0) in vec4 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = texture(tex, uv); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "texturecube_array<float> tex");
    // Cube array: coord.xyz + uint(rint(coord.w)).
    try assertContains(msl, ".xyz, uint(rint(");
    try assertContains(msl, ".w))");
    // Must NOT degrade to the non-array cube/2d type.
    try assertNotContains(msl, "texturecube<float> tex");
    try assertNotContains(msl, "texture2d<float> tex");
}

test "T19.3: sampler2DArrayShadow → depth2d_array<float> + layer-split sample_compare" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArrayShadow tex;
        \\layout(location=0) in vec4 uv;
        \\layout(location=0) out float o;
        \\void main(){ o = texture(tex, uv); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "depth2d_array<float> tex");
    // Oracle: sample_compare(s, coord.xy, uint(rint(coord.z)), coord.w).
    try assertContains(msl, ".sample_compare(");
    try assertContains(msl, ".xy, uint(rint(");
    // Must NOT degrade to the non-array depth/texture type.
    try assertNotContains(msl, "depth2d<float> tex");
    try assertNotContains(msl, "texture2d<float> tex");
}

test "T19.4: plain sampler2D stays texture2d<float> (no array regression)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = texture(tex, uv); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<float> tex");
    try assertNotContains(msl, "texture2d_array");
    // No spurious layer-split for a non-array sampler.
    try assertNotContains(msl, "uint(rint(");
}

// ---------------------------------------------------------------------------
// T19.5–T19.8: texelFetch (OpImageFetch → .read) and textureGather
// (OpImageGather → .gather) on ARRAY textures also split the array layer (#187).
//
// Like OpImageSample*, MSL's `.read`/`.gather` take the array layer in a
// SEPARATE integer argument after the (dimension-sliced) coordinate. Before the
// fix the whole int/float coord was passed verbatim — invalid MSL.
//
// Oracle (spirv-cross --msl 1.4.341.1):
//   texelFetch(sampler2DArray p, lod)  → tex.read(uint2(p.xy), uint(p.z), lod)
//   textureGather(sampler2DArray c)    → tex.gather(s, c.xy, uint(rint(c.z)), int2(0), component::x)
//   textureGather(samplerCubeArray c)  → tex.gather(s, c.xyz, uint(rint(c.w)), component::x)
//   texelFetch(sampler2D p, lod)       → tex.read(uint2(p), lod)   [unchanged, no layer split]
// ---------------------------------------------------------------------------

test "T19.5: texelFetch(sampler2DArray) → .read splits array layer" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ ivec3 p = ivec3(1,2,3); o = texelFetch(tex, p, 0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Oracle: tex.read(uint2(p.xy), uint(p.z), 0).
    try assertContains(msl, ".read(uint2(");
    try assertContains(msl, ".xy), uint(");
    try assertContains(msl, ".z), ");
    // Must NOT pass the whole int3 coord verbatim.
    try assertNotContains(msl, ".read(p)");
}

test "T19.6: textureGather(sampler2DArray) → .gather splits array layer" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGather(tex, vec3(0.5), 0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Oracle: tex.gather(texSmplr, c.xy, uint(rint(c.z)), int2(0), component::x).
    try assertContains(msl, ".gather(");
    try assertContains(msl, ".xy, uint(rint(");
    try assertContains(msl, ".z)), ");
    try assertContains(msl, "component::x");
}

// #170/#470: NON-arrayed textureGather with an explicit component. MSL's
// gather(sampler, coord, offset, component::<swizzle>) takes the channel as a
// trailing enum; the non-arrayed path was passing the bare integer index into the
// OFFSET slot -> wrong channel sampled (silent-wrong). Matches spirv-cross
// `gather(s, uv, int2(0), component::z)`.
test "T19.6b: textureGather(sampler2D, comp=2) selects component::z via the enum, not the offset slot" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGather(tex, uv, 2); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, ".gather(");
    // Channel selected via the component enum, with an explicit offset arg.
    try assertContains(msl, "int2(0), component::z");
    // Must NOT pass the raw component index as a positional (offset) arg.
    try assertNotContains(msl, ", 2)");
}

test "T19.7: textureGather(samplerCubeArray) → .gather splits array layer" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeArray tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGather(tex, vec4(0.5), 0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Oracle: tex.gather(texSmplr, c.xyz, uint(rint(c.w)), component::x).
    try assertContains(msl, ".gather(");
    try assertContains(msl, ".xyz, uint(rint(");
    try assertContains(msl, ".w)), ");
    try assertContains(msl, "component::x");
}

test "T19.8: texelFetch(sampler2D) stays unchanged (no array-layer split)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ ivec2 p = ivec2(1,2); o = texelFetch(tex, p, 0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, ".read(");
    // No array-layer split for a non-array fetch.
    try assertNotContains(msl, "uint(rint(");
    try assertNotContains(msl, ".xy), uint(");
}

test "T19.9: int/uint sampler component type (#203) — texture2d<int>/<uint>" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform isampler2D i2;
        \\layout(binding=1) uniform usampler2D u2;
        \\layout(binding=2) uniform sampler2D  f2;
        \\layout(location=0) in vec2 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(texture(i2,c)) + vec4(texture(u2,c)) + texture(f2,c); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<int>");
    try assertContains(msl, "texture2d<uint>");
    try assertContains(msl, "texture2d<float>"); // float sampler unchanged
}

test "T19.11: samplerCubeShadow -> depthcube<float> (#208)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeShadow cs;
        \\layout(binding=1) uniform samplerCube cube;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out float o;
        \\void main(){ o = texture(cs, c) + texture(cube, c.xyz).x; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "depthcube<float>"); // cube shadow -> depth family
    try assertContains(msl, "texturecube<float>"); // non-shadow cube unchanged
    try assertNotContains(msl, "texturecube<float> cs");
}

test "T19.10: int sampler array + depth component types (#203)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform isampler1DArray i1a;
        \\layout(binding=1) uniform sampler2DShadow sh;
        \\layout(location=0) in vec2 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(texelFetch(i1a, ivec2(c), 0)) + vec4(texture(sh, vec3(c,0.5))); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "texture1d_array<int>"); // int array sampler
    try assertContains(msl, "depth2d<float>"); // depth always float
    try assertNotContains(msl, "depth2d<int>");
}

// #260: atomicCompSwap(mem, compare, data) → MSL atomic_compare_exchange_weak_explicit(
// mem, &compare, data, …). OpAtomicCompareExchange layout is [ptr][scope][eq-sem]
// [uneq-sem][value(new/data)][comparator(compare)] — data at words[7], compare at
// words[8]. The backend read compare from words[7] (the data) and data from words[6]
// (the Unequal-semantics constant), emitting `…(&9u, 64u, …)`: silent-wrong. HLSL was
// the correct reference. (cross-backend sibling of #170 / #260 GLSL fix.)
test "T-atomic.1: MSL atomic_compare_exchange reads compare/data from correct operands (#260)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { uint lock; uint out_old; } b;
        \\void main() {
        \\    uint old = atomicCompSwap(b.lock, 7u, 9u); // compare 7, set 9
        \\    b.out_old = old;
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "atomic_compare_exchange_weak_explicit(");
    // #263: the comparator must be materialized into an addressable mutable local
    // (MSL `expected` is an in/out thread pointer) — never &<literal>, which is not
    // an lvalue and does not compile.
    try assertContains(msl, "&_cas_expected_");
    try assertContains(msl, "= 7u;"); // local initialized to the comparator
    try assertContains(msl, ", 9u,"); // data passed by value (operand order, #260)
    // The original loaded value is taken from the local, not the bool return.
    try assertNotContains(msl, "&7u"); // invalid-lvalue bug (#263)
    try assertNotContains(msl, "&9u"); // operand-swap regression (#260)
    // The Unequal-semantics constant (0x40 == 64) must never appear as an argument.
    try assertNotContains(msl, "64u,");
}

// #260: atomicExchange / atomicAdd must remain correct (they read value from words[6]).
test "T-atomic.2: MSL atomic_exchange/atomic_fetch_add stay correct after compswap fix (#260)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { uint slot; uint total; uint out_old; } b;
        \\void main() {
        \\    uint old = atomicExchange(b.slot, 42u); // store 42
        \\    atomicAdd(b.total, 37u);                // add 37
        \\    b.out_old = old;
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "atomic_exchange_explicit(");
    try assertContains(msl, ", 42u,");
    try assertContains(msl, "atomic_fetch_add_explicit(");
    try assertContains(msl, ", 37u,");
}

// #260: the IMAGE variant shares the same operand decode as the SSBO path. Guard the
// text output directly — conformance only validates the produced SPIR-V, not the MSL.
test "T-atomic.3: MSL image atomic_compare_exchange reads compare/data from correct operands (#260)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32ui, binding = 0) uniform uimage2D img;
        \\layout(std430, binding = 1) buffer B { uint out_old; } b;
        \\void main() {
        \\    b.out_old = imageAtomicCompSwap(img, ivec2(0), 5u, 3u); // compare 5, set 3
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "atomic_compare_exchange_weak_explicit(");
    // #263: comparator materialized into an addressable local (see T-atomic.1).
    try assertContains(msl, "&_cas_expected_");
    try assertContains(msl, "= 5u;"); // local initialized to the comparator
    try assertContains(msl, ", 3u,"); // data passed by value
    try assertNotContains(msl, "&5u"); // invalid-lvalue bug (#263)
    try assertNotContains(msl, "&3u"); // operand-swap regression (#260)
    try assertNotContains(msl, "64u,");
    // #267: the image-atomic object now targets the backing buffer, not the broken
    // non-addressable `&img[coord]` form.
    try assertContains(msl, "img_atomic[spvImage2DAtomicCoord(");
    try assertNotContains(msl, "&img[int2(");
}

// #263: the comparator is also routed through the materialized local when it is a
// runtime VALUE (not a constant). This was the previously-compiling path (`&varname`);
// guard that it still produces a valid `&_cas_expected_` lvalue and the correct data.
test "T-atomic.4: MSL atomic_compare_exchange handles a runtime (non-constant) comparator (#263)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { uint lock; uint cmpval; uint out_old; } b;
        \\void main() {
        \\    uint c = b.cmpval;                          // runtime value — not constant-foldable
        \\    b.out_old = atomicCompSwap(b.lock, c, 9u);  // compare = c, data = 9
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "atomic_compare_exchange_weak_explicit(");
    try assertContains(msl, "&_cas_expected_"); // comparator passed via addressable local
    try assertContains(msl, ", 9u,"); // data still passed by value
    try assertNotContains(msl, "&9u"); // data must never be address-of'd
}

// #265: the atomic result must be a typed DECLARATION (`uint vN = atomic_...`), not a
// bare assignment to an undeclared SSA temp. Checks the line containing `call` has the
// type token `ty` before it (a declaration), which the old `vN = atomic_...` lacked.
fn atomicCallLineHasType(msl: []const u8, call: []const u8, ty: []const u8) bool {
    const at = std.mem.indexOf(u8, msl, call) orelse return false;
    var ls = at;
    while (ls > 0 and msl[ls - 1] != '\n') ls -= 1;
    return std.mem.indexOf(u8, msl[ls..at], ty) != null;
}

// #265: every MSL atomic must (A) cast the object to `(device|threadgroup atomic_T*)&…`
// — bare `b.total` is a plain `uint`, not an atomic pointer, so it does not compile —
// and (B) declare its SSA result temp with a type.
test "T-atomic.5: MSL device SSBO atomic casts the object + declares the result (#265)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer B { uint total; } b;
        \\void main() {
        \\    uint o = atomicAdd(b.total, 37u);
        \\    b.total = o;
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    // (A) device address-space + atomic_uint cast on the object.
    try assertContains(msl, "atomic_fetch_add_explicit((device atomic_uint*)&b.total, 37u,");
    try assertNotContains(msl, "atomic_fetch_add_explicit(b.total"); // the bare-object bug
    // (B) the result is a typed declaration, not a bare `vN = …`.
    try std.testing.expect(atomicCallLineHasType(msl, "atomic_fetch_add_explicit", "uint"));
}

test "T-atomic.6: MSL threadgroup (shared) atomic uses the threadgroup address space (#265)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\shared uint counter;
        \\layout(std430, binding = 0) buffer B { uint out0; } b;
        \\void main() {
        \\    b.out0 = atomicAdd(counter, 5u);
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "atomic_fetch_add_explicit((threadgroup atomic_uint*)&counter, 5u,");
    try assertNotContains(msl, "atomic_fetch_add_explicit(counter"); // bare-object bug
    try std.testing.expect(atomicCallLineHasType(msl, "atomic_fetch_add_explicit", "uint")); // Gap B
}

test "T-atomic.7: MSL signed atomic casts to atomic_int (#265)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer B { int sval; } b;
        \\void main() {
        \\    b.sval = atomicMin(b.sval, -5);
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "atomic_fetch_min_explicit((device atomic_int*)&b.sval, -5,");
    try assertNotContains(msl, "atomic_fetch_min_explicit(b.sval"); // bare-object bug
    try std.testing.expect(atomicCallLineHasType(msl, "atomic_fetch_min_explicit", "int"));
}

// ---------------------------------------------------------------------------
// #267: MSL storage-image atomics. Metal has no native read-write atomic on a
// texture2d; spirv-cross emulates with a buffer-backed linear texture. The
// queried image is bound as a texture AND a separate `device atomic_T*` backing
// buffer; the atomic targets `(device atomic_T*)&img_atomic[spvImage2DAtomicCoord(coord, img)]`.
// Previously zioshade emitted `&img[coord]` (not addressable in Metal) — silent-wrong.
// Oracle: spirv-cross --msl.
test "T-imgatomic.1: MSL uimage2D atomic uses spvImage2DAtomicCoord backing buffer (#267)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32ui, binding = 0) uniform uimage2D img;
        \\void main() {
        \\    uint a = imageAtomicAdd(img, ivec2(0), 7u);
        \\    uint b = imageAtomicExchange(img, ivec2(1), 3u);
        \\    imageAtomicMax(img, ivec2(2), a + b);
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    // The image is bound as a texture parameter (was entirely missing before).
    try assertContains(msl, "texture2d<uint> img [[texture(0)]]");
    // A separate atomic backing buffer is added.
    try assertContains(msl, "device atomic_uint* img_atomic [[buffer(");
    // The coord-linearization macro + alignment function-constant are emitted once.
    try assertContains(msl, "#define spvImage2DAtomicCoord(");
    try assertContains(msl, "spvLinearTextureAlignment");
    // The atomic targets the backing buffer at the linearized coord.
    try assertContains(msl, "atomic_fetch_add_explicit((device atomic_uint*)&img_atomic[spvImage2DAtomicCoord(int2(0), img)], 7u,");
    try assertContains(msl, "atomic_exchange_explicit((device atomic_uint*)&img_atomic[spvImage2DAtomicCoord(int2(1), img)], 3u,");
    try assertContains(msl, "atomic_fetch_max_explicit((device atomic_uint*)&img_atomic[spvImage2DAtomicCoord(int2(2), img)],");
    // The broken non-addressable form is gone.
    try assertNotContains(msl, "&img[int2(");
}

test "T-imgatomic.2: MSL iimage2D atomic uses atomic_int backing buffer (#267)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32i, binding = 0) uniform iimage2D img;
        \\void main() { imageAtomicAdd(img, ivec2(0), 5); }
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<int> img [[texture(0)]]");
    try assertContains(msl, "device atomic_int* img_atomic [[buffer(");
    try assertContains(msl, "atomic_fetch_add_explicit((device atomic_int*)&img_atomic[spvImage2DAtomicCoord(int2(0), img)], 5,");
}

test "T-imgatomic.3: MSL image-atomic backing buffer is appended AFTER existing buffers (#267)" {
    // An SSBO at binding 1 occupies a [[buffer]] slot; the atomic backing buffer must
    // be appended at a non-colliding higher slot, never overwriting the SSBO's.
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32ui, binding = 0) uniform uimage2D img;
        \\layout(std430, binding = 1) buffer B { uint out0; } b;
        \\void main() { b.out0 = imageAtomicAdd(img, ivec2(0), 7u); }
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "b [[buffer(1)]]"); // the SSBO keeps its slot
    try assertContains(msl, "device atomic_uint* img_atomic [[buffer(2)]]"); // appended above it
}

test "T-imgatomic.4: MSL image atomics honest-error under argument buffers (#267)" {
    // Argument-buffer layout for the atomic backing buffer is out of scope; fail loud.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32ui, binding = 0) uniform uimage2D img;
        \\void main() { imageAtomicAdd(img, ivec2(0), 7u); }
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, zioshade.spirvToMSL(alloc, spirv, .{ .argument_buffers = true }));
}

test "T-imgatomic.5: MSL image atomics in a FRAGMENT shader honest-error (#267)" {
    // The buffer-backed scheme is implemented for the compute path only; a fragment
    // image atomic would need impl-helper backing-buffer threading. Fail loud rather
    // than emit the old non-compiling &img[coord].
    const source: [:0]const u8 =
        \\#version 450
        \\layout(r32ui, binding = 0) uniform uimage2D img;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(float(imageAtomicAdd(img, ivec2(0), 7u))); }
    ;
    try std.testing.expectError(error.UnsupportedOp, compileToMslStage(source, .fragment));
}

// ---------------------------------------------------------------------------
// #284: compute kernels never bound storage/sampled images as parameters — the
// kernel signature omitted them entirely, so a body `img.read()/.write()`
// referenced an undeclared identifier (silent-wrong, non-compiling). Storage
// images also need the right `access::` qualifier (read+write → read_write,
// writeonly → write, readonly/atomic-only → none) for `.write()` to compile.
// Oracle: spirv-cross --msl.
test "T-imgrw.1: MSL compute binds a read+write image2D as access::read_write (#284)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32f, binding = 0) uniform image2D img;
        \\void main() {
        \\    vec4 c = imageLoad(img, ivec2(0));
        \\    imageStore(img, ivec2(1), c * 2.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<float, access::read_write> img [[texture(0)]]");
    try assertContains(msl, "img.read(");
    try assertContains(msl, "img.write(");
}

test "T-imgrw.2: MSL compute binds a writeonly image2D as access::write (#284)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32f, binding = 0) writeonly uniform image2D img;
        \\void main() { imageStore(img, ivec2(0), vec4(1.0)); }
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<float, access::write> img [[texture(0)]]");
    try assertContains(msl, "img.write(");
}

test "T-imgrw.3: MSL compute binds a readonly image2D with default (sample) access (#284)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32f, binding = 0) readonly uniform image2D img;
        \\layout(std430, binding = 1) buffer B { vec4 o; } b;
        \\void main() { b.o = imageLoad(img, ivec2(0)); }
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<float> img [[texture(0)]]"); // no access:: for read-only
    try assertContains(msl, "img.read(");
}

test "T-imgrw.4: MSL atomic-only image keeps default access, no read_write (#284 vs #267)" {
    // An atomic-only image must NOT gain access::read_write (its read/write goes through
    // the backing buffer, not the texture) — the #267 texture binding stays unqualified.
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32ui, binding = 0) uniform uimage2D img;
        \\void main() { imageAtomicAdd(img, ivec2(0), 1u); }
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<uint> img [[texture(0)]]");
    try assertNotContains(msl, "access::read_write");
}

test "T-imgrw.5: MSL compute binds a sampled texture + sampler (#284)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(binding = 0) uniform sampler2D samp;
        \\layout(std430, binding = 1) buffer B { vec4 o; } b;
        \\void main() { b.o = texture(samp, vec2(0.5)); }
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<float> samp [[texture(0)]]");
    try assertContains(msl, "sampler sampSmplr [[sampler(0)]]");
    try assertContains(msl, "samp.sample(");
}

test "T-imgrw.6: MSL image used for BOTH atomic and imageStore keeps default texture access (#284/#267)" {
    // The image is in atomic_images, so the #267 path binds it. A co-occurring imageStore
    // must NOT push the texture to access::write (which would forbid the .get_width() the
    // spvImage2DAtomicCoord macro needs) — the texture stays unqualified.
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32ui, binding = 0) uniform uimage2D img;
        \\void main() {
        \\    imageAtomicAdd(img, ivec2(0), 1u);
        \\    imageStore(img, ivec2(1), uvec4(5u));
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<uint> img [[texture(0)]]"); // no access::write
    try assertNotContains(msl, "access::write");
    try assertContains(msl, "spvImage2DAtomicCoord("); // the atomic path still works
}

// #284 follow-up: the fragment, vertex, non-entry, and argument-buffer
// texture-emission paths unconditionally emitted `sampler {name}Smplr` for
// EVERY texture, including STORAGE images (image2D/uimage2D). Storage images
// don't support `.sample()`, so the sampler is dead — it compiles (unused
// param) but diverges from spirv-cross, which emits NO sampler for a storage
// image. The compute path was guarded in #284 (`if (tex.is_storage)`); these
// tests pin the remaining sites to the same `!tex.is_storage` behaviour.
// Oracle: spirv-cross --msl.
test "T-imgrw.7: MSL fragment storage image emits NO sampler (#284 follow-up)" {
    const source =
        \\#version 450
        \\layout(r32f, binding = 0) uniform image2D img;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    imageStore(img, ivec2(0), vec4(1.0));
        \\    o = imageLoad(img, ivec2(0));
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, "img [[texture(0)]]"); // texture still bound
    try assertNotContains(msl, "imgSmplr"); // but NO dead sampler anywhere
}

test "T-imgrw.8: MSL vertex storage image emits NO sampler (#284 follow-up)" {
    const source =
        \\#version 450
        \\layout(r32f, binding = 0) uniform image2D img;
        \\void main() {
        \\    gl_Position = imageLoad(img, ivec2(0));
        \\}
    ;
    const msl = try compileToMslStage(source, .vertex);
    defer alloc.free(msl);
    try assertContains(msl, "img [[texture(0)]]");
    try assertNotContains(msl, "imgSmplr");
}

test "T-imgrw.9: MSL non-entry helper with storage image emits NO sampler (#284 follow-up)" {
    // Every non-entry function gets ALL textures appended to its signature, so a
    // helper that touches the storage image exercises the function-signature and
    // call-forwarding sites.
    const source =
        \\#version 450
        \\layout(r32f, binding = 0) uniform image2D img;
        \\layout(location = 0) out vec4 o;
        \\vec4 helper() { return imageLoad(img, ivec2(0)); }
        \\void main() { o = helper(); }
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, "img [[texture(0)]]");
    try assertNotContains(msl, "imgSmplr");
}

test "T-imgrw.10: MSL argbuf storage image takes ONE [[id]] slot, no sampler (#284 follow-up)" {
    // In an argument buffer a storage image consumes a single [[id]] descriptor
    // slot (no sampler), so a following combined image-sampler shifts down: its
    // texture lands at id(1) and its sampler at id(2), not id(2)/id(3).
    const source =
        \\#version 450
        \\layout(set=0, r32f, binding=0) uniform image2D img;
        \\layout(set=0, binding=1) uniform sampler2D tex;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    imageStore(img, ivec2(0), vec4(1.0));
        \\    o = imageLoad(img, ivec2(0)) + texture(tex, uv);
        \\}
    ;
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{ .argument_buffers = true });
    defer alloc.free(msl);
    try assertNotContains(msl, "imgSmplr"); // storage image: no sampler
    try assertContains(msl, "img [[id(0)]]"); // texture at slot 0
    try assertContains(msl, "tex [[id(1)]]"); // sampled texture shifted to slot 1
    try assertContains(msl, "sampler texSmplr [[id(2)]]"); // its sampler at slot 2
}

// findMSB/findLSB are GLSL.std.450 FindSMsb/FindUMsb/FindILsb — NOT raw clz/ctz.
// zioshade's MSL backend mapped findLSB→ctz and findMSB→clz, which is silent-wrong:
// findMSB(1u) is 0 (the MSB *index*), but clz(1u) is 31; findLSB(0) must be -1, but
// ctz(0) is 32. The fix emits the spirv-cross helper math inline (clz(T(0)) is the bit
// width, so clz(T(0)) - (clz(x) + 1) == 31 - clz(x) for 32-bit, with the x==0 → -1 guard
// via select). Result type == arg type T (downstream bitcast handles int/uint).
test "T-bits.1: MSL findLSB lowers to select(ctz(...), -1, x==0), not bare ctz (#gaps findmsb)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { uint ui; int si; } u;
        \\void main() {
        \\    int a = findLSB(u.ui);
        \\    int b = findLSB(u.si);
        \\    o = vec4(float(a + b), 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, "select(ctz("); // -1-on-zero guard around ctz
    try assertNotContains(msl, " = ctz("); // the old bare-ctz silent-wrong form
}

test "T-bits.2: MSL findMSB(uint) lowers to the clz(T(0)) - (clz(x)+1) index, not bare clz (#gaps findmsb)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { uint ui; } u;
        \\void main() {
        \\    uint a = findMSB(u.ui);
        \\    o = vec4(float(a), 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, "select(clz("); // index = clz(T(0)) - (clz(x)+1), guarded by x==0
    try assertContains(msl, "- (clz(");
    try assertNotContains(msl, " = clz("); // the old bare-clz silent-wrong form
}

test "T-bits.3: MSL findMSB(int) flips negatives then takes the MSB index (#gaps findmsb)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { int si; } u;
        \\void main() {
        \\    int a = findMSB(u.si);
        \\    o = vec4(float(a), 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    // Signed findMSB flips negatives (v = x<0 ? ~x : x via -1 - x) before the clz index.
    try assertContains(msl, "_fmsb_");
    try assertContains(msl, "select(clz(");
    try assertNotContains(msl, " = clz("); // the old bare-clz silent-wrong form
}

test "T-bits.4: MSL findLSB/findMSB are componentwise for vectors (typed splats) (#gaps findmsb)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { uvec2 uv; ivec2 sv; } u;
        \\void main() {
        \\    ivec2 a = findLSB(u.uv);
        \\    ivec2 b = findMSB(u.sv);
        \\    o = vec4(float(a.x + b.y), 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    // Math computed in the (vector) arg type with typed splats, cast to the result type.
    try assertContains(msl, "uint2(-1)"); // findLSB(uvec2): -1 splat in the arg type
    try assertContains(msl, "uint2(0)"); // zero-guard splat in the arg type
    try assertContains(msl, "int2(select("); // result cast to ivec2
    try assertContains(msl, "int2(-1) - "); // signed-vector negative flip (findMSB(ivec2))
}

// packHalf2x16/unpackHalf2x16 have NO MSL builtin — Metal converts via half + as_type.
// zioshade emitted the invented `pack_float_to_half2x16`/`unpack_half2x16_to_float`, which
// do not exist → non-compiling MSL. The unorm/snorm variants (pack_float_to_unorm2x16,
// etc.) ARE real MSL builtins and stay. spirv-cross: `as_type<uint>(half2(x))` /
// `float2(as_type<half2>(x))`.
test "T-pack.1: MSL packHalf2x16/unpackHalf2x16 use half+as_type, not invented builtins (#gaps packhalf)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { vec2 v2; uint p; } u;
        \\void main() {
        \\    uint a = packHalf2x16(u.v2);
        \\    vec2 b = unpackHalf2x16(u.p);
        \\    o = vec4(float(a) + b.x, 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, "= as_type<uint>(half2("); // packHalf2x16 (declared uint)
    try assertContains(msl, "= float2(as_type<half2>("); // unpackHalf2x16 (declared float2)
    try assertNotContains(msl, "pack_float_to_half2x16"); // invented, non-existent builtin
    try assertNotContains(msl, "unpack_half2x16_to_float"); // invented, non-existent builtin
}

// Regression guard: the unorm/snorm pack/unpack builtins are REAL MSL functions and must
// be left untouched by the packHalf fix.
test "T-pack.2: MSL unorm/snorm pack/unpack keep their real MSL builtins (#gaps packhalf)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { vec2 v2; vec4 v4; uint p; } u;
        \\void main() {
        \\    uint a = packUnorm2x16(u.v2);
        \\    uint b = packSnorm4x8(u.v4);
        \\    vec4 c = unpackUnorm4x8(u.p);
        \\    o = vec4(float(a + b) + c.w, 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, "pack_float_to_unorm2x16(");
    try assertContains(msl, "pack_float_to_snorm4x8(");
    try assertContains(msl, "unpack_unorm4x8_to_float(");
    // The invented half builtins must never reappear, even alongside the real ones.
    try assertNotContains(msl, "pack_float_to_half2x16");
    try assertNotContains(msl, "unpack_half2x16_to_float");
}

// GLSL inverse(matN) has NO MSL builtin — Metal has no matrix `inverse()`. zioshade emitted
// a bare `inverse(m)` → non-compiling MSL. Fix mirrors the WGSL backend + spirv-cross: emit
// an emit-once spvInverseNxN cofactor/adjugate helper and call it.
test "T-inv.1: MSL inverse(matN) calls an emit-once spvInverse helper, not a phantom builtin (#gaps inverse)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { mat2 m2; mat3 m3; mat4 m4; } u;
        \\void main() {
        \\    mat2 a = inverse(u.m2);
        \\    mat3 b = inverse(u.m3);
        \\    mat4 c = inverse(u.m4);
        \\    o = vec4(a[0].x + b[1].y + c[2].z, 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    // Helper definitions emitted once in the preamble…
    try assertContains(msl, "float2x2 spvInverse2x2(float2x2 m)");
    try assertContains(msl, "float3x3 spvInverse3x3(float3x3 m)");
    try assertContains(msl, "float4x4 spvInverse4x4(float4x4 m)");
    // …and called at the use site, never the non-existent MSL `inverse()`.
    try assertContains(msl, "= spvInverse2x2(");
    try assertContains(msl, "= spvInverse3x3(");
    try assertContains(msl, "= spvInverse4x4(");
    try assertNotContains(msl, "= inverse("); // the phantom MSL builtin call
    // zioshade emits no forward declarations, so the helper DEFINITION must precede its
    // call site or the MSL won't compile (Metal = C++ definition-before-use).
    const def3 = std.mem.indexOf(u8, msl, "float3x3 spvInverse3x3(float3x3 m)").?;
    const call3 = std.mem.indexOf(u8, msl, "= spvInverse3x3(").?;
    try std.testing.expect(def3 < call3);
}

// Emit-once: a helper is only emitted for the dims actually used, and only once.
test "T-inv.2: MSL spvInverse helper is emitted once and only for used dims (#gaps inverse)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { mat3 m3; } u;
        \\void main() {
        \\    mat3 a = inverse(u.m3);
        \\    mat3 b = inverse(a);
        \\    o = vec4(a[0].x + b[1].y, 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, "float3x3 spvInverse3x3(float3x3 m)");
    // Only the mat3 helper — not mat2/mat4.
    try assertNotContains(msl, "spvInverse2x2(float2x2");
    try assertNotContains(msl, "spvInverse4x4(float4x4");
    // Defined exactly once despite two call sites.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, msl, "float3x3 spvInverse3x3(float3x3 m)"));
}

// Integer clamp (GLSL.std.450 SClamp/UClamp) must lower to plain `clamp`, NOT
// `fast::clamp` — `metal::fast::clamp` is a float-only fast-math op; applied to ints it
// converts through float (precision loss past 2^24) or fails to compile. spirv-cross uses
// plain `clamp` for integer clamp (fast::clamp only for float, GLSL FClamp).
test "T-clamp.1: MSL integer clamp uses clamp(), not fast::clamp() (#gaps sclamp)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { int si; ivec2 sv; uint ui; } u;
        \\void main() {
        \\    int a = clamp(u.si, 2, 8);          // SClamp
        \\    ivec2 b = clamp(u.sv, ivec2(1), ivec2(9)); // SClamp (vector)
        \\    uint c = clamp(u.ui, 2u, 8u);        // UClamp
        \\    o = vec4(float(a + b.x) + float(c), 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, "= clamp("); // integer clamp lowers to plain clamp
    // No float clamp in this source, so the absence of `fast::clamp` is unambiguous
    // evidence the integer (S/UClamp) paths use plain clamp.
    try assertNotContains(msl, "fast::clamp"); // never the float-only fast-math op on ints
}

// GLSL.std.450 UMin(38)/UMax(41) — UNSIGNED min/max — must lower to min()/max(), not the
// reverse. The MSL/HLSL/GLSL backends used a wrong F/S/U-grouping numbering (38→max,
// 41→min), so min(uint) emitted max() and max(uint) emitted min() — a silent-wrong
// miscompile on every unsigned min/max. (Signed/float were correct; WGSL was correct.)
test "T-umm.1: MSL unsigned+signed min/max are not swapped (#272)" {
    // Both unsigned AND signed min in one shader: every op must be `min`, never `max`
    // (guards both the unsigned swap and an over-correction of the signed path).
    const min_src =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { uint ui; int si; } u;
        \\void main() { uint a = min(u.ui, 7u); int e = min(u.si, 3); o = vec4(float(a) + float(e), 0.0, 0.0, 1.0); }
    ;
    const m = try compileToMslStage(min_src, .fragment);
    defer alloc.free(m);
    try assertContains(m, "min(");
    try assertNotContains(m, "max(");

    const max_src =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { uint ui; int si; } u;
        \\void main() { uint b = max(u.ui, 9u); int f = max(u.si, 5); o = vec4(float(b) + float(f), 0.0, 0.0, 1.0); }
    ;
    const x = try compileToMslStage(max_src, .fragment);
    defer alloc.free(x);
    try assertContains(x, "max(");
    try assertNotContains(x, "min(");
}

// bitfieldExtract / bitfieldInsert (SPIR-V OpBitField{SExtract,UExtract,Insert} = 202/203/
// 201) were unhandled → `// unhandled op N` (undeclared result, non-compiling). MSL has
// extract_bits/insert_bits (overloaded by signedness); offset/width are uint, so cast.
test "T-bf.1: MSL bitfieldExtract/bitfieldInsert lower to extract_bits/insert_bits (#gaps bitfield)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { int si; uint ui; } u;
        \\void main() {
        \\    int a = bitfieldExtract(u.si, 3, 8);   // OpBitFieldSExtract
        \\    uint b = bitfieldExtract(u.ui, 2, 5);  // OpBitFieldUExtract
        \\    int c = bitfieldInsert(u.si, 5, 2, 6); // OpBitFieldInsert
        \\    o = vec4(float(a + c) + float(b), 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .fragment);
    defer alloc.free(msl);
    try assertContains(msl, "extract_bits(");
    try assertContains(msl, "insert_bits(");
    try assertContains(msl, ", uint(3), uint(8))"); // offset/width cast to uint (signed extract)
    try assertNotContains(msl, "// unhandled");
}

// textureQueryLod (OpImageQueryLod=105) was unhandled → `// unhandled op 105`,
// non-compiling. MSL calculate_clamped_lod/calculate_unclamped_lod require MSL 2.2+.
const querylod_src =
    \\#version 450
    \\layout(location = 0) out vec4 o;
    \\layout(binding = 0) uniform sampler2D s;
    \\layout(binding = 1) uniform U { vec2 v; } u;
    \\void main() {
    \\    vec2 lod = textureQueryLod(s, u.v);
    \\    o = vec4(lod.x, lod.y, 0.0, 1.0);
    \\}
;

test "T-qlod.1: MSL textureQueryLod emits calculate_clamped/unclamped_lod on MSL 2.2+ (#278)" {
    const msl = try compileToMslStageVer(querylod_src, .fragment, 22);
    defer alloc.free(msl);
    try assertContains(msl, ".calculate_clamped_lod("); // .x = clamped LOD
    try assertContains(msl, ".calculate_unclamped_lod("); // .y = unclamped LOD
    try assertNotContains(msl, "// unhandled");
}

test "T-qlod.2: MSL textureQueryLod honest-errors below MSL 2.2 (#278)" {
    // calculate_*_lod don't exist before MSL 2.2, so zioshade must fail loud (matching
    // spirv-cross, which refuses ImageQueryLod when metal_version < 22) rather than emit
    // non-compiling MSL.
    try std.testing.expectError(error.UnsupportedOp, compileToMslStageVer(querylod_src, .fragment, 21));
}

test "T-qlod.3: the MSL 2.2 query guard does not trip a plain-sampling shader (#278)" {
    // A shader WITHOUT textureQueryLod must still compile at metal_version 21 — the guard
    // is scoped to OpImageQueryLod only.
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(binding = 1) uniform U { vec2 v; } u;
        \\void main() { o = texture(s, u.v); }
    ;
    const msl = try compileToMslStageVer(source, .fragment, 21);
    defer alloc.free(msl);
    try assertContains(msl, ".sample(");
    try assertNotContains(msl, "// unhandled");
}

// ---------------------------------------------------------------------------
// #271: pull-model interpolation (interpolateAtCentroid/Sample/Offset).
// Metal's pull-model interpolation requires the fragment input to be declared
// as `interpolant<T, interpolation::P>` and queried via METHOD calls
// (in.v.interpolate_at_centroid()), not the non-existent free functions the
// backend used to emit (interpolate_at_centroid(in.v)). It is an MSL 2.3+
// feature; below 2.3 we honest-error (matching spirv-cross). Oracle:
// spirv-cross --msl --msl-version 30000.
const interp_src: [:0]const u8 =
    \\#version 450
    \\layout(location = 0) in vec2 v;
    \\layout(location = 0) out vec4 o;
    \\void main() {
    \\    vec2 a = interpolateAtCentroid(v);
    \\    vec2 b = interpolateAtSample(v, 2);
    \\    vec2 c = interpolateAtOffset(v, vec2(0.1));
    \\    o = vec4(a + b + c, 0.0);
    \\}
;

test "T-interp.1: MSL pull-model interpolation uses interpolant<> + method calls on 2.3+ (#271)" {
    const msl = try compileToMslStageVer(interp_src, .fragment, 23);
    defer alloc.free(msl);
    // Input field becomes interpolant<float2, interpolation::perspective>.
    try assertContains(msl, "interpolant<float2, interpolation::perspective>");
    // Method-call form, not the non-existent free functions.
    try assertContains(msl, ".interpolate_at_centroid()");
    try assertContains(msl, ".interpolate_at_sample(");
    try assertContains(msl, ".interpolate_at_offset(");
    // spirv-cross's GLSL→Metal offset fixup, emitted only on the offset method call.
    try assertContains(msl, "+ 0.4375");
    // The old broken free-function call must be gone.
    try assertNotContains(msl, "interpolate_at_centroid(in");
    try assertNotContains(msl, "// unhandled");
}

test "T-interp.2: MSL pull-model interpolation honest-errors below MSL 2.3 (#271)" {
    // interpolant<> + method-call interpolation is MSL 2.3+. Below it, fail loud
    // rather than emit non-compiling MSL (matching spirv-cross's refusal).
    try std.testing.expectError(error.UnsupportedOp, compileToMslStageVer(interp_src, .fragment, 22));
}

test "T-interp.3: a plain read of a pull-model input becomes interpolate_at_center() (#271)" {
    // Once an input is declared interpolant<>, EVERY read must be a method call;
    // a plain (non-pull) read of the same input lowers to .interpolate_at_center().
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 v;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(interpolateAtCentroid(v) + v, 0.0); }
    ;
    const msl = try compileToMslStageVer(src, .fragment, 23);
    defer alloc.free(msl);
    try assertContains(msl, ".interpolate_at_centroid()");
    try assertContains(msl, ".interpolate_at_center()");
    try assertNotContains(msl, "// unhandled");
}

test "T-interp.4: the MSL 2.3 interpolation guard does not trip a plain-input shader (#271)" {
    // A shader with plain location inputs and NO pull-model interpolation must
    // still compile below 2.3 — the guard is scoped to InterpolateAt* ExtInsts.
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 v;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(v, 0.0, 1.0); }
    ;
    const msl = try compileToMslStageVer(src, .fragment, 21);
    defer alloc.free(msl);
    try assertNotContains(msl, "interpolant<");
    try assertNotContains(msl, "// unhandled");
}

// #296: runtime-sized SSBO array `.length()` (OpArrayLength) now lowers to MSL's
// `spvBufferSizeConstants` scheme (spirv-cross's). A host-bound `constant uint*
// spvBufferSizeConstants [[buffer(N)]]` array (appended above all SSBO/UBO slots) carries
// each storage buffer's byte size; the length is `(size - memberOffset) / elementStride`.
// Wired for the compute, non-argbuf path (no co-occurring image-atomic backing buffer);
// other shapes honest-error. MSL is spirv-cross-gated (no Metal compiler), so this guards
// the emitted string against the spirv-cross oracle form.
test "T-arrlen.1: runtime SSBO array .length() lowers to spvBufferSizeConstants in MSL (#296)" {
    const source: [:0]const u8 = "#version 450\nlayout(local_size_x=1) in;\nlayout(std430,binding=0) buffer B { float d[]; };\nlayout(std430,binding=1) buffer Out { uint n; };\nvoid main(){ n = uint(d.length()); }";
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    // The host-bound size buffer is declared as a kernel param at the next free [[buffer]]
    // slot ABOVE the two SSBOs (0,1) — slot 2; pinning it guards the slot computation.
    try assertContains(msl, "constant uint* spvBufferSizeConstants [[buffer(2)]]");
    // length = (size - offset) / stride; member offset 0, float stride 4.
    try assertContains(msl, "spvBufferSizeConstants[0]");
    try assertContains(msl, ") / 4");
    try assertNotContains(msl, "// unhandled");
}

// #296: multi-member SSBO `{ uint count; float data[]; }` — the runtime array is member 1
// at byte offset 4 (after the uint). The length formula subtracts that member offset:
// (size - 4) / 4. Exercises the OpMemberDecorate Offset scan (the single-member case has
// offset 0, so the subtraction is invisible there).
test "T-arrlen.3: multi-member SSBO .length() uses the member byte offset in MSL (#296)" {
    const source: [:0]const u8 = "#version 450\nlayout(local_size_x=1) in;\nlayout(std430,binding=0) buffer B { uint count; float data[]; } b;\nlayout(std430,binding=1) buffer O { uint n; } o;\nvoid main(){ o.n = b.count + uint(b.data.length()); }";
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spirv);
    const msl = try zioshade.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    try assertContains(msl, "(spvBufferSizeConstants[0] - 4) / 4");
    try assertNotContains(msl, "// unhandled");
}

// #296: the spvBufferSizeConstants param is only injected into the legacy (non-argbuf)
// compute kernel signature, so a runtime `.length()` under argument_buffers honest-errors
// rather than referencing an unbound identifier.
test "T-arrlen.4: runtime SSBO .length() under argument_buffers honest-errors in MSL (#296)" {
    const source: [:0]const u8 = "#version 450\nlayout(local_size_x=1) in;\nlayout(std430,binding=0) buffer B { float d[]; };\nlayout(std430,binding=1) buffer Out { uint n; };\nvoid main(){ n = uint(d.length()); }";
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, zioshade.spirvToMSL(alloc, spirv, .{ .argument_buffers = true }));
}

// #296: a runtime SSBO `.length()` in a NON-compute (fragment) stage stays an honest error —
// the spvBufferSizeConstants param is only injected into the compute kernel signature, so a
// fragment `.length()` would reference an unbound identifier. Fail loud instead.
test "T-arrlen.2: runtime SSBO array .length() in a fragment shader honest-errors in MSL (#296)" {
    const source: [:0]const u8 = "#version 450\nlayout(std430,binding=0) buffer B { float d[]; };\nlayout(location=0) out float o;\nvoid main(){ o = float(d.length()); }";
    const spirv = try zioshade.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, zioshade.spirvToMSL(alloc, spirv, .{}));
}

// #170: a NESTED sampler array (`sampler1D s[2][2]`) was missed by the shared
// hasOpaqueArrayResource guard (it checked only one array level), so the MSL
// backend emitted broken output (undeclared `s`, `.sample()` on a float4) instead
// of honest-erroring like it does for single-level sampler arrays. Pins the
// cross-backend behaviour now that the guard unwraps every array level.
test "T-samplerarr.nested: nested sampler array honest-errors in MSL (#170)" {
    const spirv = compileToSpirv("nested_sampler_array",
        \\#version 450
        \\layout(binding = 0) uniform sampler1D s[2][2];
        \\layout(location = 0) flat in float c;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = texture(s[0][1], c) + texture(s[1][0], c); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedSamplerArray, zioshade.spirvToMSL(alloc, spirv, .{}));
}

// #170: MSL ImageSampleExplicitLod IGNORED the Grad image operand (mask 0x4) —
// it only handled Lod (0x2) and otherwise fell through to sample(..., level(0)).
// So textureGrad dropped its gradients entirely and sampled LOD 0 = valid-but-
// wrong (wrong mip). spirv-cross emits sample(..., gradient2d(dPdx, dPdy)).
test "T-grad.msl: textureGrad carries gradient2d, not level(0) (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec2 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGrad(s, c, vec2(0.1), vec2(0.2)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "gradient2d(");
    try assertNotContains(msl, "level(0)");
}

// The MSL gradient constructor is DIMENSION-specific: gradient2d / gradient3d /
// gradientcube. Emitting gradient2d for a sampler3D/samplerCube (whose gradients
// are float3) is invalid MSL — so the Dim must drive the constructor choice.
test "T-grad.msl3d: textureGrad(sampler3D) uses gradient3d (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler3D s;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGrad(s, c, vec3(0.1), vec3(0.2)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "gradient3d(");
    try assertNotContains(msl, "gradient2d(");
}

test "T-grad.mslcube: textureGrad(samplerCube) uses gradientcube (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform samplerCube s;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGrad(s, c, vec3(0.1), vec3(0.2)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "gradientcube(");
    try assertNotContains(msl, "gradient2d(");
}

// #170: textureGradOffset → MSL sample(..., gradient2d(dPdx,dPdy), offset). The
// trailing const offset (ConstOffset image operand) must survive; the old Grad arm
// had no ConstOffset case (see #402) and would drop it.
test "T-gradoff.msl: textureGradOffset carries the const offset (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec2 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureGradOffset(s, c, vec2(0.1), vec2(0.2), ivec2(1, -1)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "gradient2d(");
    try assertContains(msl, "int2(1, -1)");
}

// #170: textureProjLodOffset → MSL sample(coord.xy / divisor, level(lod), int2 offset).
// The offset is a trailing arg after level(); dropping it samples the un-offset texels.
test "T-projlodoff.msl: textureProjLodOffset carries the const offset (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjLodOffset(s, c, 1.0, ivec2(2, -1)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "level(");
    try assertContains(msl, "int2(2, -1)");
}

// #170: textureProjGradOffset → MSL sample(coord.xy / divisor, gradient2d(ddx,ddy), int2 offset).
test "T-projgradoff.msl: textureProjGradOffset carries the const offset (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjGradOffset(s, c, vec2(0.1), vec2(0.2), ivec2(2, -1)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "gradient2d(");
    try assertContains(msl, "int2(2, -1)");
}

// #170: textureProjOffset → MSL sample(coord.xy / divisor, int2 offset).
test "T-projoff.msl: textureProjOffset carries the const offset (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjOffset(s, c, ivec2(2, -1)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, ".sample(");
    try assertContains(msl, "int2(2, -1)");
}

// #170: textureProjGrad → MSL sample(coord.xy / divisor, gradient2d(dPdx, dPdy)).
// Shares OpImageSampleProjExplicitLod with textureProjLod; the arm must emit the
// gradient form (not level()) for the Grad mask, with the vec3 .z divisor.
test "T-projgrad.msl: textureProjGrad uses gradient2d with the .z divisor (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) in vec3 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjGrad(s, c, vec2(0.1), vec2(0.2)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "gradient2d(");
    try assertContains(msl, ".xy / ");
    try assertContains(msl, ".z");
    try assertNotContains(msl, "level(");
}

// #170: the MSL proj-explicit arm faithfully lowers only 2D (the .xy numerator /
// gradient2d assume 2D). textureProjGrad/textureProjLod on a sampler3D would drop
// the r-coordinate and use the wrong gradient rank — honest-error, not silent-wrong.
// (WGSL lowers 3D proj correctly; this is an MSL-only limit.)
test "T-projgrad.msl3d: textureProjGrad(sampler3D) honest-errors in MSL (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler3D s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjGrad(s, c, vec3(0.1), vec3(0.2)); }
    ;
    try std.testing.expectError(error.CrossCompileUnsupported, compileToMsl(source));
}

// #170: plain textureProj(sampler3D) (proj-IMPLICIT-lod) is the same 2D-only limit
// as the proj-explicit arm — the .xy numerator drops the r-coordinate. Honest-error
// in MSL rather than silently sample a 2D location in a 3D texture.
test "T-proj.msl3d: textureProj(sampler3D) honest-errors in MSL (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler3D s;
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProj(s, c); }
    ;
    try std.testing.expectError(error.CrossCompileUnsupported, compileToMsl(source));
}

// #474: fragment barycentric coordinates (gl_BaryCoordEXT / gl_BaryCoordNV) have
// NO Metal builtin — the emitter would otherwise write a bare `gl_BaryCoordEXT`
// identifier that Metal rejects deep in makeLibrary. Fail loud with a precise
// UnsupportedBarycentric error at the cross-compile layer instead. Keyed on the
// BaryCoord* BuiltIn decoration, so shaders that merely compute barycentrics by
// hand (no builtin) are untouched and still compile.
test "T-barycentric.msl: gl_BaryCoordEXT honest-errors in MSL (#474)" {
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_EXT_fragment_shader_barycentric : require
        \\layout(location = 0) out vec2 value;
        \\layout(location = 0) pervertexEXT in vec2 vUV[3];
        \\void main () {
        \\    value = gl_BaryCoordEXT.x * vUV[0] + gl_BaryCoordEXT.y * vUV[1] + gl_BaryCoordEXT.z * vUV[2];
        \\}
    ;
    try std.testing.expectError(error.UnsupportedBarycentric, compileToMsl(source));
}

// #474: ARM tensors (GL_ARM_tensors: tensorARM<>, tensorReadARM, tensorSizeARM)
// have no Metal type at all, so tensor operands lower to undeclared identifiers.
// Fail loud with UnsupportedTensor keyed on the TypeTensorARM opcode rather than
// emitting MSL that Metal rejects.
test "T-tensor.msl: ARM tensor types honest-error in MSL (#474)" {
    const source: [:0]const u8 =
        \\#version 460
        \\#extension GL_ARM_tensors : require
        \\#extension GL_EXT_shader_explicit_arithmetic_types : require
        \\layout(location = 0) out vec4 outColor;
        \\layout(set=0, binding=0) uniform tensorARM<uint8_t, 3> tens;
        \\void main() {
        \\  const uint size_d1 = tensorSizeARM(tens, 1);
        \\  uint8_t tensorValue = uint8_t(0);
        \\  tensorReadARM(tens, uint[](uint(0), uint(0), 1), tensorValue);
        \\  outColor = vec4(0.0, tensorValue, 0.0, 255.0);
        \\}
    ;
    try std.testing.expectError(error.UnsupportedTensor, compileToMsl(source));
}

// #474: reading gl_ClipDistance / gl_CullDistance in a FRAGMENT shader has no
// Metal form (clip_distance is a vertex OUTPUT attribute only), so the emitter
// would write undeclared gl_ClipDistance / gl_CullDistance identifiers. Honest-
// error instead. Scoped to the fragment stage: vertex clip/cull output IS
// expressible in MSL, so this gate must not touch it (compileToMsl compiles as
// fragment, which is the gated case).
test "T-clipcull.msl: fragment gl_ClipDistance/gl_CullDistance honest-errors in MSL (#474)" {
    const source: [:0]const u8 =
        \\#version 450
        \\in float gl_ClipDistance[4];
        \\in float gl_CullDistance[3];
        \\layout(location = 0) out float FragColor;
        \\void main() {
        \\    FragColor = gl_ClipDistance[0] + gl_CullDistance[0];
        \\}
    ;
    try std.testing.expectError(error.UnsupportedFragmentClipCullDistance, compileToMsl(source));
}

// #475: gl_HelperInvocation has no MSL input attribute; Metal spells it as the
// simd_is_helper_thread() intrinsic. Was leaking as an undeclared gl_HelperInvocation
// identifier (uncompilable). Mirrors the HLSL IsHelperLane() path. Aliased at the
// load so each use reads current helper state; not gated on stage since the load
// often lives in a non-entry helper function (fragment-only builtin regardless).
test "T-helperinv.msl: gl_HelperInvocation lowers to simd_is_helper_thread() (#475)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() { o = gl_HelperInvocation ? vec4(1.0) : vec4(0.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "simd_is_helper_thread()");
    try assertNotContains(msl, "gl_HelperInvocation");
}

// #476: a location varying (vUV) read inside a NON-entry function (foo) was
// emitted as a bare `vUV` there, undeclared, because inputs are aliased to
// `in.<name>` only in scope in the entry. Thread `main0_in in` into non-entry
// fragment functions and pass `in` at the call site so the varying resolves.
// (This is the corpus helper-invocation.frag, which the frontend keeps as a real
// foo() rather than inlining.) Also exercises the #475 helper-invocation lowering.
test "T-staturein-helper.msl: varying used in a non-entry function is threaded (#476)" {
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out vec4 FragColor;
        \\layout(location = 0) in vec2 vUV;
        \\layout(binding = 0) uniform sampler2D uSampler;
        \\vec4 foo() {
        \\    vec4 color;
        \\    if (!gl_HelperInvocation)
        \\        color = textureLod(uSampler, vUV, 0.0);
        \\    else
        \\        color = vec4(1.0);
        \\    return color;
        \\}
        \\void main() { FragColor = foo(); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // foo() receives the stage-in struct and reads the varying through it.
    try assertContains(msl, "main0_in in");
    try assertContains(msl, "in.vUV");
    // No bare varying reference leaks into the helper.
    try assertNotContains(msl, ", vUV,");
}

// #414: an `in` parameter whose value seeds a written-then-read local (the
// classic `float d = p; loop { d = ... }` shape) was misdetected as an out
// param: the Variable+Store(param) prologue is just GLSL's by-value copy of
// the param INTO the local, not a write-back. The param was emitted as
// `thread float&` (and call sites pass rvalues into it: hard error), the
// local was aliased to the param name (redeclaration), and the entry copy
// degenerated to a self-assign of an undefined value.
test "msl: in param seeding a written-then-read local stays a value param (#414)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float t; } ub;
        \\layout(location = 0) out vec4 fragColor;
        \\float map(float p) {
        \\    float d = p;
        \\    for (int m = 0; m < 4; m++) {
        \\        d = max(d, sin(d * float(m)));
        \\    }
        \\    return d;
        \\}
        \\void main() { fragColor = vec4(map(ub.t)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float map(float ");
    try assertNotContains(msl, "thread float&");
    const open = (std.mem.indexOf(u8, msl, "float map(float ") orelse return error.TestExpectedFind) + "float map(float ".len;
    const close = std.mem.indexOfAnyPos(u8, msl, open, ",)") orelse return error.TestExpectedFind;
    const param = std.mem.trim(u8, msl[open..close], " ");
    const redecl = try std.fmt.allocPrint(alloc, "float {s};", .{param});
    defer alloc.free(redecl);
    try assertNotContains(msl, redecl);
    const selfassign = try std.fmt.allocPrint(alloc, "{s} = {s};", .{ param, param });
    defer alloc.free(selfassign);
    try assertNotContains(msl, selfassign);
    const copy = try std.fmt.allocPrint(alloc, " = {s};", .{param});
    defer alloc.free(copy);
    try assertContains(msl, copy);
}

// #414 scope guard (mirrors the WGSL negative test): a read-only param whose
// name is shadowed by a mutated inner-block local must not be promoted to an
// out param either: the entry copy `float r = p;` is the exact
// Variable+Store(param) shape the misdetection keyed on.
test "msl: read-only param shadowed by a mutated inner local is not promoted (#414)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float t; } ub;
        \\layout(location = 0) out vec4 o;
        \\float f(float p) {
        \\    float r = p;
        \\    for (int i = 0; i < 3; i++) { float p = ub.t; p += float(i); r += p; }
        \\    return r + p;
        \\}
        \\void main() { o = vec4(f(ub.t)); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float f(float ");
    try assertNotContains(msl, "thread float&");
}

// ---------------------------------------------------------------------------
// #413: loop-carried phi read before declaration
// ---------------------------------------------------------------------------

/// #413: assert no SSA temp (`v<digits>`) is referenced textually before the
/// statement that declares it. The rotated-loop emission (#237) copies phi
/// carries at the loop TOP (`v98 = v106;`) while the temp carrying the value
/// was declared later in the body (`float v106 = v98 + v103;`) — the Metal
/// compiler rejects the output with an undeclared-identifier error. A
/// declaration site is an occurrence whose previous token is another
/// identifier (its type); statement keywords are excluded so `return v5;`
/// counts as a use.
fn assertNoUseBeforeDecl(src: []const u8) !void {
    const keywords = [_][]const u8{ "return", "else", "if", "while", "for", "do", "case", "in", "out", "inout", "const", "break", "continue", "discard" };
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }
    var i: usize = 0;
    while (i < src.len) {
        if (!(std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
        const tok = src[i..j];
        const start = i;
        i = j;
        // Only SSA temps: v<digits>
        if (tok.len < 2 or tok[0] != 'v') continue;
        var all_digits = true;
        for (tok[1..]) |ch| {
            if (!std.ascii.isDigit(ch)) {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) continue;
        // Declaration = previous token (skipping spaces) is a type-like identifier.
        var k = start;
        while (k > 0 and (src[k - 1] == ' ' or src[k - 1] == '\t')) k -= 1;
        var is_decl = false;
        if (k > 0 and (std.ascii.isAlphanumeric(src[k - 1]) or src[k - 1] == '_')) {
            var t0 = k;
            while (t0 > 0 and (std.ascii.isAlphanumeric(src[t0 - 1]) or src[t0 - 1] == '_')) t0 -= 1;
            const prev = src[t0..k];
            is_decl = true;
            for (keywords) |kw| {
                if (std.mem.eql(u8, prev, kw)) {
                    is_decl = false;
                    break;
                }
            }
        }
        if (is_decl and seen.contains(tok)) {
            std.debug.print("#413: `{s}` is referenced before its declaration in output:\n{s}\n", .{ tok, src });
            return error.UseBeforeDeclaration;
        }
        if (!seen.contains(tok)) {
            const dup = try alloc.dupe(u8, tok);
            try seen.put(dup, {});
        }
    }
}

// #413: a function whose loop updates its carried locals at the END of the
// body (the classic fbm / raymarch accumulator shape) has those locals
// promoted to loop phis whose update value is DEFINED IN THE BODY. The
// top-of-loop carry copy then read the update temp before its declaration.
test "msl: loop-carried phi update defined in the body is declared before the loop top reads it (#413)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 res; float time; } ub;
        \\layout(location = 0) out vec4 fragColor;
        \\float fbm(vec2 p) {
        \\    float v = 0.0;
        \\    float a = 0.5;
        \\    for (int i = 0; i < 5; i++) {
        \\        v += a * fract(sin(dot(floor(p), vec2(12.9898, 78.233))) * 43758.5453);
        \\        p = p * 2.03 + vec2(1.7, 9.2);
        \\        a *= 0.5;
        \\    }
        \\    return v;
        \\}
        \\void main() {
        \\    fragColor = vec4(fbm(gl_FragCoord.xy / ub.res.xy));
        \\}
    ;
    const out = try compileToMsl(source);
    defer alloc.free(out);
    try assertContains(out, "while (true)");
    try assertNoUseBeforeDecl(out);
}

// #413 raymarcher shape from the issue: inlined mainImage with a marching
// loop (conditional breaks + trailing `t += d`) calling a map() that itself
// loops. Guards the whole-program shape, not just the minimal trigger.
test "msl: raymarcher with inlined-function loops has no use-before-declaration (#413)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 res; float time; } ub;
        \\layout(location = 0) out vec4 _fragColor;
        \\float map(vec3 p) {
        \\    float d = length(p) - 1.0;
        \\    for (int i = 0; i < 3; i++) {
        \\        d = min(d, length(p - vec3(float(i))) - 0.5);
        \\    }
        \\    return d;
        \\}
        \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        \\    vec3 ro = vec3(0.0, 0.0, -3.0);
        \\    vec3 rd = normalize(vec3(fragCoord / ub.res.xy - 0.5, 1.0));
        \\    float t = 0.0;
        \\    int hit = 0;
        \\    for (int i = 0; i < 64; i++) {
        \\        float d = map(ro + rd * t);
        \\        if (d < 0.001) { hit = 1; break; }
        \\        if (t > 20.0) break;
        \\        t += d;
        \\    }
        \\    fragColor = vec4(vec3(1.0 - t * 0.05), 1.0) + float(hit);
        \\}
        \\void main() { mainImage(_fragColor, gl_FragCoord.xy); }
    ;
    const out = try compileToMsl(source);
    defer alloc.free(out);
    try assertContains(out, "while (true)");
    try assertNoUseBeforeDecl(out);
}

test "T417.LOOSE: loose non-block uniforms are gathered into struct _Globals" {
    // #417: MSL has no bare global uniform, so loose (non-block) uniforms are
    // synthesized into a single `struct _Globals` bound as `_Globals_1`. Body
    // references must be qualified as `_Globals_1.<name>`, never a bare
    // undefined `iResolution` nor an empty per-uniform `struct iResolution {}`.
    const source =
        \\#version 430
        \\uniform vec2 iResolution;
        \\uniform float iTime;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    fragColor = vec4(iResolution / iTime, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "struct _Globals");
    try assertContains(msl, "float2 iResolution");
    try assertContains(msl, "_Globals_1.iResolution");
    // No stray empty per-uniform struct named after the loose uniform.
    try assertNotContains(msl, "struct iResolution");
}

test "T417.SSBO: _Globals buffer slot does not collide with an SSBO" {
    // #417 correctness bug: in MSL, UBOs and SSBOs share the [[buffer(N)]]
    // index space. When a loose uniform coexists with an SSBO, _Globals must
    // take a slot ABOVE the SSBO's binding, not `max(cbuffer)+1` (which was 0
    // and aliased the SSBO at binding 0 onto the same [[buffer(0)]]).
    const source =
        \\#version 430
        \\layout(local_size_x = 1) in;
        \\uniform vec2 iResolution;
        \\layout(std430, binding = 0) buffer B { vec4 data[]; };
        \\void main() {
        \\    data[0] = vec4(iResolution, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    // The SSBO keeps [[buffer(0)]]; _Globals must NOT also claim buffer(0).
    try assertContains(msl, "[[buffer(0)]]");
    try assertContains(msl, "_Globals_1 [[buffer(1)]]");
    try assertNotContains(msl, "_Globals_1 [[buffer(0)]]");
}

// ---- Compute differential regressions (found by tools/compute_diff.sh) ----
// These four SPIR-V opcodes were mistranslated by the MSL backend, each verified
// wrong by running both toolchains' MSL on the Metal GPU and diffing the output
// buffers. The zioshade frontend emits the same SPIR-V as glslang for all four
// (confirmed with spirv-dis), so the defect was purely in SPIR-V -> MSL.

test "OpFMod uses GLSL-mod sign semantics, not Metal fmod (silent-wrong for negatives)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (mod(u.a, 3.0) > 0.5) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // GLSL mod(x,y) = x - y*floor(x/y) (sign of y). Metal fmod takes the sign of x,
    // so an fmod lowering silently diverges for negative operands.
    try assertContains(msl, "floor(");
    try assertNotContains(msl, "fmod(");
}

test "OpBitcast reinterprets bits via as_type, not a numeric conversion (silent-wrong)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (uintBitsToFloat(floatBitsToUint(u.a) + 1u) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // floatBitsToUint(x) must be as_type<uint>(x), not uint(x) which would round.
    try assertContains(msl, "as_type<");
}

test "degrees/radians lower to a multiply, not a nonexistent Metal builtin (won't compile)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (degrees(u.a) + radians(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Metal has no degrees()/radians(); spirv-cross and now zioshade emit the
    // defining multiply (180/pi, pi/180).
    try assertNotContains(msl, "degrees(");
    try assertNotContains(msl, "radians(");
    try assertContains(msl, "57.29577");
    try assertContains(msl, "0.017453");
}

test "OpVectorExtractDynamic (matrix-column dynamic index) emits vec[idx], not an unhandled stub" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat3 m; int i; } u;
        \\void main() { if (u.m[1][u.i] > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertNotContains(msl, "unhandled op");
}

// Mirrors the GLSL value-struct fix: a struct used via an inlined function reaches
// the output as an OpCompositeConstruct value. It must be DECLARED, and constructed
// with C++ aggregate brace-init `Light{ ... }` — Metal structs have no call-style
// constructor, so `Light(a,b,c)` fails to compile. Built from runtime input so the
// struct survives constant folding. Found by the backend validity sweep.
test "value struct is declared and brace-initialized (Metal has no struct ctor)" {
    const source =
        \\#version 450
        \\layout(location=0) in vec3 p;
        \\layout(location=0) out vec4 o;
        \\struct Light { vec3 pos; float intensity; };
        \\vec3 shade(vec3 x, Light l){ return l.pos * (l.intensity / (length(x - l.pos) + 0.01)); }
        \\void main(){ Light a = Light(p, p.x); Light b = Light(p.zyx, p.y); o = vec4(shade(p, a) + shade(p, b), 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "struct Light");
    try assertContains(msl, "Light{ ");
    try assertNotContains(msl, "= Light(");
}

// OpOuterProduct has no Metal builtin; it is built column-by-column
// (matCxR(v1*v2[0], v1*v2[1], …), Metal being column-major like the SPIR-V
// result). Verified bit-exact vs SPIRV-Cross MSL on the GPU by
// tools/compute_corpus/13_outerproduct.comp. Previously `// unhandled op 147`.
test "OpOuterProduct builds the matrix from columns, not an unhandled stub" {
    const source =
        \\#version 450
        \\layout(location=0) in vec3 p;
        \\layout(location=0) out vec4 o;
        \\void main(){ mat3 m = outerProduct(p, p.zyx); o = vec4(m[0] + m[1] + m[2], 1.0); }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertNotContains(msl, "unhandled op");
    try assertContains(msl, "float3x3(");
}

// A struct passed by pointer param (`inout Particle p`) with a local-variable arg
// had two bugs mirrored from GLSL: emitted by-value (writes lost) and member access
// as `v14[1]` instead of `.vel`. Metal passes any out/inout param as `thread T&`
// (a Function-storage pointer param is always out/inout per the frontend), and
// resolvePointee now handles the OpFunctionParameter base. gl_FragCoord keeps the
// function un-inlined.
test "struct pointer param is thread T& with .member access (not by-value [idx])" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 fragColor;
        \\struct Particle { vec2 pos; vec2 vel; float life; };
        \\void updateParticle(inout Particle p, float dt){ p.pos = p.pos + p.vel * dt; p.life -= dt; if (p.life < 0.0) p.life = 0.0; }
        \\void main(){
        \\  vec2 uv = gl_FragCoord.xy / 300.0;
        \\  Particle p; p.pos = uv; p.vel = vec2(0.01, -0.02); p.life = 1.0;
        \\  for (int i = 0; i < 5; i++) { updateParticle(p, 0.1); }
        \\  fragColor = vec4(p.pos, p.life, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "thread Particle&");
    try assertContains(msl, ".vel");
    try assertNotContains(msl, "v14[1]");
}

// A value that differs by branch (`x = cond ? a : b`, or a conditional mutation) is
// a selection-merge OpPhi. MSL has block scope, so the branch-local temp is out of
// scope after the `if`; the phi must be materialized as a persistent `_phi` var and
// the post-merge use must read it. Before the fix the merge value was aliased to the
// branch-local temp (undeclared identifier after the block = Metal rejects it).
test "selection-merge phi is materialized as a persistent _phi variable" {
    const source =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\  float x = uv.x;
        \\  float row = floor(uv.y * 5.0);
        \\  if (mod(row, 2.0) > 0.5) { x += 0.5; }
        \\  float result = fract(x * 4.0);
        \\  fragColor = vec4(result, 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The phi is a `_phi` var, initialized to the fall-through value and assigned in
    // the branch; the post-merge multiply reads it.
    try assertContains(msl, "_phi = ");
    try assertContains(msl, "_phi * 4.0");
}

// A struct OpConstantComposite must fold to a Metal brace initializer
// `Type{...}` (Metal has no struct call-constructor); before the fix it got a bare
// vNN name and was never declared, so its use referenced an undeclared identifier.
test "struct constant folds to a Metal brace initializer" {
    const source =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\struct Light { vec3 color; float intensity; };
        \\void main() {
        \\  Light lights[2];
        \\  lights[0] = Light(vec3(1.0, 0.0, 0.0), 0.5);
        \\  lights[1] = Light(vec3(0.0, 1.0, 0.0), 0.8);
        \\  int i = clamp(int(uv.x * 2.0), 0, 1);
        \\  fragColor = vec4(lights[i].color * lights[i].intensity, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // The struct constant is inlined as `Light{...}` at the array-element assignment,
    // not left as a bare undeclared vNN.
    try assertContains(msl, "] = Light{");
}

// A switch case that declares a variable then falls through to the next case is a
// jump over an in-scope initialization, which Metal rejects. Each case body must be
// braced so its temps are scoped. (Fall-through control flow is unaffected.)
test "switch case bodies are braced so fall-through does not jump over a declaration" {
    const source =
        \\#version 450
        \\layout(location = 0) flat in int mode;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\  vec3 c = vec3(0.0);
        \\  switch (mode) {
        \\    case 2: c.r = 0.5; // fall through
        \\    case 1: { vec3 t = c + vec3(0.0, 0.3, 0.0); c = t; } // fall through
        \\    default: { vec3 u = c + vec3(0.1); c = u; }
        \\  }
        \\  fragColor = vec4(c, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Each emitted case body is braced.
    try assertContains(msl, "case 2: {");
    try assertContains(msl, "case 1: {");
}

// Metal's texture.read() takes an UNSIGNED coordinate; a texelFetch hands it a
// signed ivec, so the read must cast (`uint2(coord)`) or Metal rejects the call.
test "texelFetch read casts its integer coordinate to unsigned" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform highp isampler2D Buf;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\  ivec4 c = texelFetch(Buf, ivec2(gl_FragCoord.xy), 0);
        \\  FragColor = vec4(c);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, ".read(uint2(");
}

// A shader that reads gl_FragCoord.z (depth) or .w needs the FULL float4 threaded
// into the impl; the .xy-only case stays float2. Threading only .xy made `.z`
// exceed the float2 and Metal rejected it.
test "gl_FragCoord.z reader threads the full float4 fragcoord" {
    const zw =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(gl_FragCoord.xy / 128.0, gl_FragCoord.z, 1.0); }
    ;
    const xy =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(gl_FragCoord.xy / 128.0, 0.0, 1.0); }
    ;
    const msl_zw = try compileToMsl(zw);
    defer alloc.free(msl_zw);
    const msl_xy = try compileToMsl(xy);
    defer alloc.free(msl_xy);
    try assertContains(msl_zw, "float4 _fragCoord");
    try assertContains(msl_xy, "float2 _fragCoord"); // xy-only stays float2
}
