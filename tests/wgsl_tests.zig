// SPDX-License-Identifier: MIT OR Apache-2.0
//! WGSL backend tests — GLSL → SPIR-V → WGSL pipeline.

const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

const ShaderTest = struct {
    name: [:0]const u8,
    source: [:0]const u8,
};

fn compileToSpirv(name: []const u8, source: [:0]const u8) ![]u32 {
    // Write source to temp file
    const tmp_src = try std.fmt.allocPrint(alloc, "/tmp/wgsl_test_{s}.frag", .{name});
    defer alloc.free(tmp_src);
    const tmp_spv = try std.fmt.allocPrint(alloc, "/tmp/wgsl_test_{s}.spv", .{name});
    defer alloc.free(tmp_spv);

    {
        const src_file = try std.fs.createFileAbsolute(tmp_src, .{});
        defer src_file.close();
        try src_file.writeAll(std.mem.sliceTo(source, 0));
    }

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe", "-V", tmp_src, "-o", tmp_spv },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const spv_file = try std.fs.openFileAbsolute(tmp_spv, .{ .mode = .read_only });
    defer spv_file.close();
    const data = try spv_file.readToEndAlloc(alloc, 1024 * 1024);
    // Convert bytes to u32 words with proper alignment
    const words_len = data.len / 4;
    const words = try alloc.alloc(u32, words_len);
    for (0..words_len) |i| {
        words[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
    }
    alloc.free(data);
    return words;
}

fn assertNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle)) |_| {
        std.debug.print("Did NOT expect to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedFind;
    }
}

fn assertContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Expected to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedFind;
    }
}

// Validate WGSL with naga — the external WebGPU validator. The whole point of
// the "silent-wrong" class of bugs is that glslpp emits text that LOOKS fine
// (exit 0) but a real validator rejects, so string assertions alone can pass
// while the output is still invalid. naga is the ground truth. When naga isn't
// installed we SKIP rather than fail, keeping `zig build test` hermetic.
fn nagaValidateOrSkip(wgsl: []const u8, label: []const u8) !void {
    const probe = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "naga", "--version" },
    }) catch return error.SkipZigTest;
    alloc.free(probe.stdout);
    alloc.free(probe.stderr);
    if (!(probe.term == .Exited and probe.term.Exited == 0)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "out.wgsl", .data = wgsl });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath("out.wgsl", &path_buf);

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "naga", "--input-kind", "wgsl", tmp_path },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term == .Exited and result.term.Exited == 0) return;
    std.debug.print("naga REJECTED WGSL for [{s}]:\n{s}\n{s}\n--- WGSL ---\n{s}\n", .{ label, result.stdout, result.stderr, wgsl });
    return error.NagaValidationFailed;
}

/// Compile GLSL → SPIR-V → WGSL via glslpp's own frontend (mirrors the MSL/HLSL
/// test helpers). Caller frees the result.
fn compileToWgsl(source: [:0]const u8) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try glslpp.spirvToWGSL(alloc, spirv, .{});
}

fn runWgslTest(test_case: ShaderTest) !void {
    const spirv = compileToSpirv(test_case.name, test_case.source) catch |err| {
        std.debug.print("FAIL [{s}]: glslang failed: {}\n", .{ test_case.name, err });
        return err;
    };
    defer alloc.free(spirv);

    const wgsl = glslpp.spirvToWGSL(alloc, spirv, .{}) catch |err| {
        std.debug.print("FAIL [{s}]: spirvToWGSL failed: {}\n", .{ test_case.name, err });
        return err;
    };
    defer alloc.free(wgsl);

    if (wgsl.len == 0) {
        std.debug.print("FAIL [{s}]: WGSL output is empty\n", .{test_case.name});
        return error.TestEmptyOutput;
    }

    try assertNotContains(wgsl, "unhandled op");
}

test "wgsl basic color output" {
    try runWgslTest(.{
        .name = "basic",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    fragColor = vec4(1.0, 0.0, 0.0, 1.0);
        \\}
        ,
    });
}

test "wgsl arithmetic" {
    try runWgslTest(.{
        .name = "arithmetic",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float a = 1.0 + 2.0;
        \\    float b = a * 3.0;
        \\    fragColor = vec4(b, b, b, 1.0);
        \\}
        ,
    });
}

test "wgsl builtin functions" {
    try runWgslTest(.{
        .name = "builtins",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float x = sin(0.5);
        \\    float y = cos(0.5);
        \\    float z = sqrt(x * x + y * y);
        \\    fragColor = vec4(x, y, z, 1.0);
        \\}
        ,
    });
}

test "wgsl struct access" {
    try runWgslTest(.{
        .name = "struct_access",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\struct Foo { float a; float b; };
        \\void main() {
        \\    Foo f;
        \\    f.a = 1.0;
        \\    f.b = 2.0;
        \\    fragColor = vec4(f.a, f.b, 0.0, 1.0);
        \\}
        ,
    });
}

test "wgsl control flow" {
    try runWgslTest(.{
        .name = "control_flow",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float x = 0.0;
        \\    if (x > 0.5) {
        \\        x = 1.0;
        \\    } else {
        \\        x = 0.0;
        \\    }
        \\    fragColor = vec4(x, 0.0, 0.0, 1.0);
        \\}
        ,
    });
}

test "wgsl vector operations" {
    try runWgslTest(.{
        .name = "vector_ops",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 a = vec3(1.0, 2.0, 3.0);
        \\    vec3 b = vec3(4.0, 5.0, 6.0);
        \\    float d = dot(a, b);
        \\    vec3 n = normalize(a);
        \\    fragColor = vec4(n, d);
        \\}
        ,
    });
}

test "wgsl mix and clamp" {
    try runWgslTest(.{
        .name = "mix_clamp",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float x = mix(0.0, 1.0, 0.5);
        \\    float y = clamp(x, 0.0, 0.8);
        \\    fragColor = vec4(x, y, 0.0, 1.0);
        \\}
        ,
    });
}

test "wgsl type conversions" {
    try runWgslTest(.{
        .name = "conversions",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int i = 42;
        \\    float f = float(i);
        \\    uint u = uint(f);
        \\    fragColor = vec4(float(i), f, float(u), 1.0);
        \\}
        ,
    });
}

// An unmapped GLSL.std.450 extended instruction (interpolateAtCentroid →
// glslpp opcode 76) must make the WGSL backend FAIL LOUDLY, not silently emit
// invalid `unknown(...)` text. interpolateAt* are frontend-supported but
// unmapped in the WGSL ext-inst dispatch, so they exercise the fallback path.
//
// Compiled through glslpp's own frontend (not glslang) so the internal
// GLSL.std.450 numbering (76/77/78) is what reaches spirvToWGSL.
test "wgsl unmapped ext-inst errors honestly instead of emitting unknown()" {
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_ARB_gpu_shader5 : enable
        \\layout(location = 0) in vec2 vUv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 c = interpolateAtCentroid(vUv);
        \\    fragColor = vec4(c, 0.0, 1.0);
        \\}
    ;

    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    try std.testing.expectError(
        error.UnsupportedExtInst,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );
}

// WGSL has no matrix-inverse builtin. GLSL inverse() (GLSL.std.450 MatrixInverse)
// must fail loud rather than emit `matrixInverse(m)`, which naga rejects with
// "no definition in scope" — the silent-wrong this milestone forbids.
test "wgsl inverse() errors honestly (WGSL has no matrix-inverse builtin)" {
    // Build the matrix from vertex inputs (not a UBO) so this targets only the
    // MatrixInverse honest-error path. (A separate pre-existing struct-name
    // error-path leak in spirvToWGSL is tracked as a follow-up.)
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 c0;
        \\layout(location = 1) in vec4 c1;
        \\layout(location = 2) in vec4 c2;
        \\layout(location = 3) in vec4 c3;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    mat4 m = mat4(c0, c1, c2, c3);
        \\    fragColor = inverse(m) * vec4(1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    try std.testing.expectError(
        error.UnsupportedExtInst,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );
}

// textureGatherOffsets lowers (correctly, for the SPIR-V target) to
// OpImageGather carrying the ConstOffsets image operand — a per-texel
// 4-offset array. WGSL's `textureGather` cannot take a 4-offset array, so the
// WGSL backend must FAIL LOUDLY rather than silently emit a plain
// `textureGather` that drops the offsets. ImageGather IS otherwise mapped in
// WGSL, so it needs a specific ConstOffsets guard (the unmapped-op path does
// not cover it).
test "wgsl: textureGatherOffsets (ConstOffsets) is an honest error, not a silent plain gather" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  const ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs, 1);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    try std.testing.expectError(
        error.UnsupportedImageOperands,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );
}

// A GLSL `sampler2DShadow` lowers to an OpTypeImage with the Depth operand set
// (word[4] == 1). WGSL's `textureGatherCompare` / `textureSampleCompare`
// builtins REQUIRE a `texture_depth_2d` texture paired with a
// `sampler_comparison` sampler. The backend defaulted every texture to
// `texture_2d<f32>` + plain `sampler`, producing WGSL that glslpp emits without
// error (exit 0) but that naga REJECTS:
//
//   "Comparison sampling mismatch: image has class Sampled { kind: Float, ... },
//    but the sampler is comparison=false, and the reference was provided=true"
//
// That is a silent-wrong cross-compile. The resource TYPES must follow the
// depth/comparison nature of the image.
test "wgsl: sampler2DShadow gather emits texture_depth_2d + sampler_comparison" {
    try runShadowValidTest(.{
        .name = "shadow_gather",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow shadowTex;
        \\layout(location=0) in vec2 vUV;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureGather(shadowTex, vUV, vRef); }
        ,
        .tex_decl = "var shadowTex: texture_depth_2d;",
        .builtin = "textureGatherCompare",
        // gather keeps the coordinate (vUV) and reference separate — no slice.
        .coord_swizzle = null,
    });
}

test "wgsl: sampler2DShadow compare-sample emits texture_depth_2d + sampler_comparison" {
    try runShadowValidTest(.{
        .name = "shadow_sample",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow shadowTex;
        \\layout(location=0) in vec2 vUV;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowTex, vec3(vUV, vRef))); }
        ,
        .tex_decl = "var shadowTex: texture_depth_2d;",
        .builtin = "textureSampleCompare",
        // glslang packs the ref into the coordinate (vec3); it must be sliced
        // to vec2. This `.xy` guard catches the coordinate-dimension bug even
        // when naga is unavailable (string assertions alone would not).
        .coord_swizzle = ".xy",
    });
}

// samplerCubeShadow → texture_depth_cube; the packed vec4(dir, ref) coordinate
// must be sliced to the 3-component cube coordinate (.xyz).
test "wgsl: samplerCubeShadow emits texture_depth_cube + sampler_comparison" {
    try runShadowValidTest(.{
        .name = "shadow_cube",
        .source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeShadow shadowCube;
        \\layout(location=0) in vec3 vDir;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowCube, vec4(vDir, vRef))); }
        ,
        .tex_decl = "var shadowCube: texture_depth_cube;",
        .builtin = "textureSampleCompare",
        .coord_swizzle = ".xyz",
    });
}

// textureLod on a shadow sampler lowers to OpImageSampleDrefExplicitLod →
// textureSampleCompareLevel, which (a) needs the same coordinate slice and
// (b) takes NO explicit level argument (it always samples mip 0). Emitting the
// raw coordinate + a trailing float level is rejected by naga.
test "wgsl: textureLod(sampler2DShadow) emits valid textureSampleCompareLevel" {
    try runShadowValidTest(.{
        .name = "shadow_lod",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow shadowTex;
        \\layout(location=0) in vec2 vUV;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(textureLod(shadowTex, vec3(vUV, vRef), 0.0)); }
        ,
        .tex_decl = "var shadowTex: texture_depth_2d;",
        .builtin = "textureSampleCompareLevel",
        .coord_swizzle = ".xy",
    });
}

// Arrayed depth textures (sampler2DArrayShadow) need a SEPARATE WGSL array_index
// argument: textureSampleCompare(t, s, coord.xy, array_index, depth_ref). glslang
// packs the layer into the coordinate (vec4: uv, layer, ref); the layer component
// must be extracted, rounded, and passed as its own i32 argument. Emitting
// texture_depth_2d + a 2-component coordinate (dropping the layer) VALIDATES in
// naga but silently samples the wrong layer — the very silent-wrong this guards.
test "wgsl: sampler2DArrayShadow emits texture_depth_2d_array + separate array_index" {
    try runShadowValidTest(.{
        .name = "shadow_2d_array",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArrayShadow shadowArr;
        \\layout(location=0) in vec4 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowArr, vC)); }
        ,
        .tex_decl = "var shadowArr: texture_depth_2d_array;",
        .builtin = "textureSampleCompare",
        // 2D spatial coordinate is .xy; the layer (.z) becomes a separate arg.
        .coord_swizzle = ".xy",
        .array_index = ".z))",
    });
}

// samplerCubeArrayShadow → texture_depth_cube_array. The coordinate is a vec4
// (dir.xyz + layer.w); the direction is sliced to vec3 and the layer (.w) becomes
// a separate rounded i32 array_index argument. The compare reference is a
// separate GLSL argument, so it is NOT packed into the coordinate here.
test "wgsl: samplerCubeArrayShadow emits texture_depth_cube_array + separate array_index" {
    try runShadowValidTest(.{
        .name = "shadow_cube_array",
        .source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeArrayShadow shadowCubeArr;
        \\layout(location=0) in vec4 vC;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowCubeArr, vC, vRef)); }
        ,
        .tex_decl = "var shadowCubeArr: texture_depth_cube_array;",
        .builtin = "textureSampleCompare",
        // Cube spatial coordinate is .xyz; the layer (.w) becomes a separate arg.
        .coord_swizzle = ".xyz",
        .array_index = ".w))",
    });
}

// textureLod on an arrayed shadow sampler lowers to OpImageSampleDrefExplicitLod
// → textureSampleCompareLevel, exercising the OTHER branch of emitDepthCompare:
// the array layer must STILL be split out as a separate i32 array_index (and the
// SPIR-V Lod operand dropped — WGSL's compare-level builtin always samples mip 0).
// Requires GL_EXT_texture_shadow_lod for textureLod() on a shadow sampler.
test "wgsl: textureLod(sampler2DArrayShadow) emits textureSampleCompareLevel + array_index" {
    try runShadowValidTest(.{
        .name = "shadow_2d_array_lod",
        .source =
        \\#version 450
        \\#extension GL_EXT_texture_shadow_lod : require
        \\layout(binding=0) uniform sampler2DArrayShadow shadowArr;
        \\layout(location=0) in vec4 vC;
        \\layout(location=1) in float vLod;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(textureLod(shadowArr, vC, vLod)); }
        ,
        .tex_decl = "var shadowArr: texture_depth_2d_array;",
        .builtin = "textureSampleCompareLevel",
        .coord_swizzle = ".xy",
        .array_index = ".z))",
    });
}

// textureGatherCompare on an ARRAYED shadow sampler also needs a separate
// array_index argument, which the gather path does not yet build. Until it does,
// it must stay an honest error rather than emit wrong-arity textureGatherCompare
// (the same silent-wrong class). The sample path above IS supported; only the
// gather-array path remains gated.
test "wgsl: textureGather(sampler2DArrayShadow) is an honest error, not wrong-arity" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArrayShadow shadowArr;
        \\layout(location=0) in vec3 vC;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureGather(shadowArr, vC, vRef); }
    ;
    const spirv = try compileToSpirv("shadow_gather_array", source);
    defer alloc.free(spirv);
    try std.testing.expectError(
        error.UnsupportedDepthArrayTexture,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );
}

const ShadowCase = struct {
    name: []const u8,
    source: [:0]const u8,
    tex_decl: []const u8,
    builtin: []const u8,
    /// Expected coordinate swizzle proving the packed coordinate was sliced to
    /// the texture dimension; null when the form keeps the coordinate as-is
    /// (e.g. gather). A naga-independent regression guard.
    coord_swizzle: ?[]const u8,
    /// For arrayed depth textures, the distinguishing tail of the SEPARATE
    /// array_index argument (e.g. ".z))" for texture_depth_2d_array, ".w))" for
    /// texture_depth_cube_array). null for non-arrayed forms. Proves the array
    /// layer was preserved as its own integer argument rather than silently
    /// folded into the coordinate or dropped.
    array_index: ?[]const u8 = null,
};

fn runShadowValidTest(c: ShadowCase) !void {
    const spirv = try compileToSpirv(c.name, c.source);
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);

    // The depth texture must be emitted with its exact comparison type (the
    // exact decl also rules out the silent-wrong `texture_2d<f32>` for it)...
    try assertContains(wgsl, c.tex_decl);
    // ...the companion sampler must be a comparison sampler...
    try assertContains(wgsl, "sampler_comparison");
    // ...the compare builtin must still be emitted (regression guard). Match the
    // trailing "(" so "textureSampleCompare" does not spuriously satisfy a case
    // that actually emitted "textureSampleCompareLevel" (the former is a prefix
    // of the latter), and vice versa...
    const builtin_call = try std.fmt.allocPrint(alloc, "{s}(", .{c.builtin});
    defer alloc.free(builtin_call);
    try assertContains(wgsl, builtin_call);
    // ...the coordinate must be sliced to the texture dimension (naga-free guard)...
    if (c.coord_swizzle) |swz| try assertContains(wgsl, swz);
    // ...an arrayed depth texture must pass the layer as its own rounded i32
    // array_index argument (naga-free guard against the dropped-layer bug)...
    if (c.array_index) |ai| {
        try assertContains(wgsl, "i32(round(");
        try assertContains(wgsl, ai);
    }
    // ...and (single-texture fixture) no plain sampled texture must appear.
    try assertNotContains(wgsl, "texture_2d<f32>");
    // Ground truth: the emitted WGSL must actually validate.
    try nagaValidateOrSkip(wgsl, c.name);
}

test "WGSL: unmapped ext-inst error names the GLSL.std.450 instruction" {
    // interpolateAtCentroid lowers to GLSL.std.450 InterpolateAtCentroid (76),
    // which has no WGSL equivalent. The honest error must NAME the instruction
    // (+ opcode) so the user knows what was unsupported — not a bare error name.
    const source =
        \\#version 450
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = interpolateAtCentroid(c); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    try std.testing.expectError(
        error.UnsupportedExtInst,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );

    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "InterpolateAtCentroid") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "76") != null);
}

// ---------------------------------------------------------------------------
// row_major / column_major UBO matrix layout (silent-wrong fix)
//
// WGSL has no row_major language feature — matrices are always column-major and
// `m[i]` returns COLUMN i (like GLSL/MSL). So the column_major case is already
// correct, but glslpp emitted byte-identical WGSL for a row_major block: a
// row_major matrix's std140 bytes are the row-major layout of M, which WGSL
// reads (column-major) as Mᵀ — silent-wrong. The fix mirrors the MSL backend:
// wrap reads of a row_major matrix in `transpose(...)` so the stored Mᵀ is read
// back as the logical M. Non-square row_major needs swapped declared dimensions
// (not yet implemented) → honest error, never silent-wrong.
// ---------------------------------------------------------------------------

const WRM_ROW_SRC: [:0]const u8 =
    \\#version 450
    \\layout(binding=0,std140,row_major) uniform A { mat4 m; } a;
    \\layout(location=0) out vec4 o;
    \\void main() { o = a.m[0]; }
;
const WRM_COL_SRC: [:0]const u8 =
    \\#version 450
    \\layout(binding=0,std140,column_major) uniform A { mat4 m; } a;
    \\layout(location=0) out vec4 o;
    \\void main() { o = a.m[0]; }
;

test "wgsl: row_major UBO matrix read is transposed; column_major is not; outputs differ" {
    const row = try compileToWgsl(WRM_ROW_SRC);
    defer alloc.free(row);
    const col = try compileToWgsl(WRM_COL_SRC);
    defer alloc.free(col);

    // Core bug: blocks differing only in layout qualifier must NOT be identical.
    if (std.mem.eql(u8, row, col)) {
        std.debug.print("row_major and column_major WGSL are byte-identical (silent-wrong):\n{s}\n", .{row});
        return error.TestUnexpectedFind;
    }
    // row_major is stored transposed → the read must transpose() it back.
    // Exact form (not a stray `transpose`) so a mis-wrapped transpose still fails.
    try assertContains(row, "transpose(a.m)[0]");
    // column_major is already correct in WGSL (column-indexed) → no transpose.
    try assertNotContains(col, "transpose");
    // Ground truth: the transposed output must actually validate.
    try nagaValidateOrSkip(row, "row_major mat4 read");
    try nagaValidateOrSkip(col, "column_major mat4 read");
}

test "wgsl: array-of-row_major matrix reads are transposed; column_major arrays are not" {
    // `mat4 m[4]` reaches the matrix via an array index. A row_major array
    // element is still stored transposed in WGSL, so both a whole-element load
    // (a.m[2], for mul) and a column read (a.m[2][0]) must transpose. The
    // column_major array stays untransposed (already correct, column-indexed).
    const row_src: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,row_major) uniform A { mat4 m[4]; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[2][0]; }
    ;
    const col_src: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,column_major) uniform A { mat4 m[4]; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[2][0]; }
    ;
    const row = try compileToWgsl(row_src);
    defer alloc.free(row);
    const col = try compileToWgsl(col_src);
    defer alloc.free(col);
    try assertContains(row, "transpose(a.m[2])[0]");
    try assertNotContains(col, "transpose");
    try nagaValidateOrSkip(row, "row_major mat4[4] read");
    try nagaValidateOrSkip(col, "column_major mat4[4] read");
}

test "wgsl: whole row_major matrix load feeding mul IS transposed (no row_major keyword in WGSL)" {
    // Unlike HLSL, WGSL has no row_major storage keyword — a row_major matrix is
    // always stored as Mᵀ, so even a whole-matrix load feeding a multiply must
    // transpose (transpose(a.m) * v). The array test's comment promises this
    // case; verify it directly. column_major stays untransposed.
    const row_src: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,row_major) uniform A { mat4 m; } a;
        \\layout(location=0) in vec4 v;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m * v; }
    ;
    const col_src: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,column_major) uniform A { mat4 m; } a;
        \\layout(location=0) in vec4 v;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m * v; }
    ;
    const row = try compileToWgsl(row_src);
    defer alloc.free(row);
    const col = try compileToWgsl(col_src);
    defer alloc.free(col);
    try assertContains(row, "transpose(a.m)");
    try assertNotContains(col, "transpose");
    try nagaValidateOrSkip(row, "row_major mat4 mul");
    try nagaValidateOrSkip(col, "column_major mat4 mul");
}

test "wgsl: non-square row_major UBO matrix is an honest error (not silent-wrong)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,row_major) uniform A { mat3x4 m; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[0]; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(
        error.UnsupportedRowMajorMatrix,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );
}
