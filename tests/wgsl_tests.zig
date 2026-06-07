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
// must NOT silently emit `matrixInverse(m)` (naga: "no definition in scope").
// Pass 2 lowers it to an emit-once generated `spvInverseN` helper (cofactor /
// determinant inverse), so the result must now be naga-validated WGSL that both
// declares the helper and calls it. Covers mat4/mat3/mat2.
test "wgsl inverse(mat4) lowers to spvInverse4 helper (naga-validated)" {
    // Build the matrix from vertex inputs (not a UBO) so this targets only the
    // MatrixInverse path. (A separate pre-existing struct-name error-path leak in
    // spirvToWGSL is tracked as a follow-up.)
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
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "fn spvInverse4(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "spvInverse4(") != null);
    // The unmapped GLSL spelling must NEVER leak.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "matrixInverse") == null);
    try nagaValidateOrSkip(wgsl, "inverse-mat4");
}

test "wgsl inverse(mat3) lowers to spvInverse3 helper (naga-validated)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec3 c0;
        \\layout(location = 1) in vec3 c1;
        \\layout(location = 2) in vec3 c2;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    mat3 m = mat3(c0, c1, c2);
        \\    fragColor = vec4(inverse(m) * vec3(1.0), 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "fn spvInverse3(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "spvInverse3(") != null);
    try nagaValidateOrSkip(wgsl, "inverse-mat3");
}

test "wgsl inverse(mat2) lowers to spvInverse2 helper (naga-validated)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 c0;
        \\layout(location = 1) in vec2 c1;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    mat2 m = mat2(c0, c1);
        \\    fragColor = vec4(inverse(m) * vec2(1.0), 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "fn spvInverse2(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "spvInverse2(") != null);
    try nagaValidateOrSkip(wgsl, "inverse-mat2");
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

// ---------------------------------------------------------------------------
// Non-depth ARRAY textures (sampler2DArray, samplerCubeArray, ...). Mirrors the
// depth-array path: the type name must carry `_array` AND the sample/fetch/gather
// call must split the array layer out as a SEPARATE i32 argument. Emitting the
// non-array type (texture_2d<f32>) with the full packed coordinate is silent-
// wrong at the glslpp level (exit 0) but naga REJECTS it ("coordinate type does
// not match dimension"). This is the #187 PART B fix.
// ---------------------------------------------------------------------------

const ArrayTexCase = struct {
    name: []const u8,
    source: [:0]const u8,
    /// Exact texture declaration line — proves the `_array` type name (rules out
    /// the silent-wrong non-array `texture_2d<f32>` / `texture_cube<f32>`).
    tex_decl: []const u8,
    /// The sample/fetch/gather builtin that must still be emitted.
    builtin: []const u8,
    /// Spatial coordinate swizzle proving the layer was sliced off (.xy for the
    /// 2D family, .xyz for cube).
    coord_swizzle: []const u8,
    /// Distinguishing tail of the SEPARATE i32 array-layer argument
    /// (e.g. ".z)" for 2d_array, ".w)" for cube_array). Proves the layer was
    /// passed as its own integer argument, not folded into the coordinate.
    array_index: []const u8,
    /// Whether the layer must be ROUNDED (`i32(round(coord.z))`). True for the
    /// FLOAT-coord sample/lod/gather sites (glslang parity: floor(layer+0.5));
    /// FALSE for the INTEGER-coord texelFetch site (layer already an integer,
    /// `i32(coord.z)` with NO round). Defaults to true.
    layer_rounded: bool = true,
};

fn runArrayTexValidTest(c: ArrayTexCase) !void {
    const spirv = try compileToSpirv(c.name, c.source);
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);

    // The arrayed texture must be emitted with its `_array` type name...
    try assertContains(wgsl, c.tex_decl);
    // ...the sample/fetch/gather builtin must still be present...
    const builtin_call = try std.fmt.allocPrint(alloc, "{s}(", .{c.builtin});
    defer alloc.free(builtin_call);
    try assertContains(wgsl, builtin_call);
    // ...the spatial coordinate must be sliced to the texture dimension...
    try assertContains(wgsl, c.coord_swizzle);
    // ...the array layer must be passed as its own i32 argument. The float-coord
    // sample/lod/gather sites must ROUND it (`i32(round(coord.z))`) for glslang
    // parity; the integer-coord texelFetch site must NOT round (`i32(coord.z)`).
    if (c.layer_rounded) {
        try assertContains(wgsl, "i32(round(");
    } else {
        try assertContains(wgsl, "i32(");
        try assertNotContains(wgsl, "i32(round(");
    }
    try assertContains(wgsl, c.array_index);
    // ...and no silent-wrong non-array sampled type must appear.
    try assertNotContains(wgsl, "texture_2d<f32>");
    try assertNotContains(wgsl, "texture_cube<f32>");
    // Ground truth: the emitted WGSL must actually validate.
    try nagaValidateOrSkip(wgsl, c.name);
}

test "wgsl: sampler2DArray texture() emits texture_2d_array + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_2d",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray arr;
        \\layout(location=0) in vec3 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = texture(arr, vC); }
        ,
        .tex_decl = "var arr: texture_2d_array<f32>;",
        .builtin = "textureSample",
        .coord_swizzle = ".xy",
        .array_index = ".z)",
    });
}

test "wgsl: samplerCubeArray texture() emits texture_cube_array + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_cube",
        .source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeArray arr;
        \\layout(location=0) in vec4 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = texture(arr, vC); }
        ,
        .tex_decl = "var arr: texture_cube_array<f32>;",
        .builtin = "textureSample",
        .coord_swizzle = ".xyz",
        .array_index = ".w)",
    });
}

test "wgsl: textureLod(sampler2DArray) emits textureSampleLevel + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_2d_lod",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray arr;
        \\layout(location=0) in vec3 vC;
        \\layout(location=1) in float vLod;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureLod(arr, vC, vLod); }
        ,
        .tex_decl = "var arr: texture_2d_array<f32>;",
        .builtin = "textureSampleLevel",
        .coord_swizzle = ".xy",
        .array_index = ".z)",
    });
}

test "wgsl: texelFetch(sampler2DArray) emits textureLoad + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_2d_fetch",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray arr;
        \\layout(location=0) flat in ivec3 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = texelFetch(arr, vC, 0); }
        ,
        .tex_decl = "var arr: texture_2d_array<f32>;",
        .builtin = "textureLoad",
        .coord_swizzle = ".xy",
        .array_index = ".z)",
        // texelFetch coord is INTEGER — the layer must NOT be rounded.
        .layer_rounded = false,
    });
}

test "wgsl: textureGather(sampler2DArray) emits textureGather + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_2d_gather",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray arr;
        \\layout(location=0) in vec3 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureGather(arr, vC, 0); }
        ,
        .tex_decl = "var arr: texture_2d_array<f32>;",
        .builtin = "textureGather",
        .coord_swizzle = ".xy",
        .array_index = ".z)",
    });
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

test "wgsl: geometry stage errors honestly (WGSL has no geometry entry point)" {
    // WGSL has only vertex/fragment/compute entry points. A geometry shader must
    // fail loud with a named error, not emit WGSL that naga rejects (silent-wrong).
    const source =
        \\#version 450
        \\layout(triangles) in;
        \\layout(triangle_strip, max_vertices = 3) out;
        \\void main() {
        \\    for (int i = 0; i < 3; i++) { gl_Position = gl_in[i].gl_Position; EmitVertex(); }
        \\    EndPrimitive();
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .geometry, .spirv_version = .@"1.5" });
    defer alloc.free(spirv);

    try std.testing.expectError(error.UnsupportedStage, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "Geometry") != null);
}

test "wgsl: scalar isnan lowers to (x != x); isinf errors honestly" {
    // WGSL has no isNan/isInf builtins. Scalar isnan(x) must lower to (x != x);
    // isinf has no clean WGSL idiom and must fail loud (not emit isinf(x), which
    // naga rejects as an undefined identifier — silent-wrong).
    {
        const source =
            \\#version 450
            \\layout(location=0) in float a;
            \\layout(location=0) out vec4 o;
            \\void main() { o = vec4(isnan(a) ? 1.0 : 0.0); }
        ;
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
        defer alloc.free(spirv);
        const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
        defer alloc.free(wgsl);
        try std.testing.expect(std.mem.indexOf(u8, wgsl, "!=") != null);
        try std.testing.expect(std.mem.indexOf(u8, wgsl, "isnan(") == null);
        try nagaValidateOrSkip(wgsl, "isnan-scalar");
    }
    {
        const source =
            \\#version 450
            \\layout(location=0) in float a;
            \\layout(location=0) out vec4 o;
            \\void main() { o = vec4(isinf(a) ? 1.0 : 0.0); }
        ;
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
        defer alloc.free(spirv);
        try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    }
}

test "wgsl: textureQueryLod errors honestly (WGSL has no equivalent)" {
    // WGSL has no textureQueryLod builtin; glslpp must fail loud, not emit
    // textureQueryLod(...) which naga rejects (silent-wrong).
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D t;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(textureQueryLod(t, uv), 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "textureQueryLod") != null);
}

test "wgsl: fragment-shader interlock errors honestly (WGSL has no interlock)" {
    // WGSL has no fragment-shader interlock. A shader with the pixel-interlock
    // execution mode must fail loud, not emit WGSL naga rejects (silent-wrong).
    const source =
        \\#version 450
        \\#extension GL_ARB_fragment_shader_interlock : require
        \\layout(pixel_interlock_ordered) in;
        \\layout(location=0) out vec4 o;
        \\void main() { beginInvocationInterlockARB(); o = vec4(1.0); endInvocationInterlockARB(); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "interlock") != null);
}

test "wgsl: unmapped input built-in (gl_PointCoord) errors honestly" {
    // gl_PointCoord has no WGSL @builtin. It must fail loud — previously it hit
    // an `else => \"position\"` fallback that fabricated a bogus
    // @builtin(position): vec2f (naga reject, silent-wrong).
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(gl_PointCoord, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "@builtin") != null);
}

test "wgsl: vertex input without explicit location is still emitted as a param" {
    // `in vec4 inV;` (no layout location) must become an `@location(N)` entry
    // parameter; previously inputs lacking a Location decoration were dropped,
    // leaving the body referencing an undeclared identifier (naga reject).
    const source =
        \\#version 450
        \\in vec4 inV;
        \\layout(location = 0) out vec4 vColor;
        \\void main() { vColor = inV; gl_Position = inV; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "inV: vec4f") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(") != null);
}

test "wgsl: vertex shader without gl_Position errors honestly" {
    // WGSL requires a @builtin(position) vertex output. A vertex shader that
    // never writes gl_Position cannot be valid WGSL; fabricating one would be
    // silent-wrong, so glslpp must fail loud.
    const source =
        \\#version 430 core
        \\in vec4 inV;
        \\layout(location = 0) out vec4 outV;
        \\void main() { outV = inV; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "gl_Position") != null);
}

test "wgsl: shared block var is renamed to avoid struct-name collision" {
    // A GLSL `shared` block with no instance name yields a struct and a var both
    // named `blk`. WGSL forbids a variable sharing its name with its type (naga:
    // "redefinition of `blk`"). The var must be renamed (struct keeps its name).
    const source =
        \\#version 450
        \\#extension GL_EXT_shared_memory_block : enable
        \\layout(local_size_x = 8) in;
        \\shared blk { int a; } ;
        \\void main() { blk.a = 2; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "struct blk {") != null);
    // The variable must NOT also be named exactly `blk` (no `var<workgroup> blk:`).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<workgroup> blk:") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<workgroup> blk_wg:") != null);
}

test "wgsl: gl_Layer / gl_ViewportIndex error honestly (no WGSL built-in)" {
    // WGSL has no layer/viewport-index built-in. A shader using gl_Layer (BuiltIn
    // Layer) must fail loud, not leak `gl_Layer` as an undeclared identifier or
    // misclassify it as a @location varying (naga reject).
    const source =
        \\#version 450
        \\#extension GL_ARB_shader_viewport_layer_array : require
        \\layout(location=0) out vec4 color;
        \\void main() { color = vec4(float(gl_Layer)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "layer") != null);
}

test "wgsl: constant unsigned vector uses WGSL vec constructor, not GLSL uintN" {
    // A uvec2 constant composite must render as `vec2<u32>(...)`, not the GLSL
    // spelling `uint2(...)` / `uvec2i(...)` which naga rejects as an undefined
    // identifier.
    const source =
        \\#version 450
        \\layout(location = 0) in vec2 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uvec2 a = uvec2(v) & uvec2(7u, 15u);
        \\    o = vec4(vec2(a), 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vec2<u32>(7u, 15u)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uint2(") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uvec2") == null);
}

test "wgsl: unsupported op in switch/loop replay path errors honestly" {
    // A cross-vector OpVectorShuffle inside a switch reaches the switch/loop
    // replay path (emitSimpleInstruction). Ops with no case there must fail loud,
    // not fall to the old fallback that emitted `<OpcodeName>(args)` (a call to a
    // non-existent WGSL function — naga reject, silent-wrong).
    const source =
        \\#version 450
        \\layout(location = 0) in vec4 a;
        \\layout(location = 1) in vec4 b;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 c = vec4(0.0);
        \\    int m = int(a.x) % 3;
        \\    switch (m) {
        \\        case 0: c = vec4(a.xy, b.zw); break;
        \\        case 1: c = b.wzyx; break;
        \\        default: c = a; break;
        \\    }
        \\    o = c;
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "replay") != null);
}

test "wgsl: textureGather emits the component as the first argument" {
    // WGSL: textureGather(component, texture, sampler, coords). The GLSL order
    // (tex, sampler, coords, component) makes naga read the texture where it
    // expects the integer component ("must resolve to u32 or i32").
    const source =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D uTex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureGather(uTex, uv, 0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Component (0) comes first, before the texture identifier.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "textureGather(0, uTex, uTex_sampler, uv)") != null);
}

test "wgsl: CompositeExtract/Select in loop-replay path do not leak opcode names" {
    // A while(true)+switch state machine drives the switch/loop replay path
    // (emitSimpleInstruction). OpCompositeExtract / OpSelect there must lower to
    // an inline access expr / select(...), not leak as `CompositeExtract(...)` /
    // `Select(...)` (opcode names, naga reject) nor `var v.x: T = ...`.
    const source =
        \\#version 450
        \\layout(location = 0) in vec3 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    int state = 0;
        \\    vec3 acc = vec3(0.0);
        \\    while (true) {
        \\        switch (state) {
        \\            case 0: acc.x = v.x; state = (v.x > 0.5) ? 2 : 1; break;
        \\            case 1: acc.y = v.y; state = 3; break;
        \\            default: state = 3; break;
        \\        }
        \\        if (state == 3) break;
        \\    }
        \\    o = vec4(acc, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "CompositeExtract") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "Select(") == null);
}

test "wgsl: nested switch does not leak OpSelectionMerge as a value" {
    // A nested switch drives the switch/loop replay path. OpSelectionMerge (a
    // structured-control-flow hint with no result id) must be skipped there, not
    // emitted as `let v = SelectionMerge();` (which naga rejects: "no definition
    // in scope for identifier: SelectionMerge").
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int mode = int(gl_FragCoord.x) % 4;
        \\    vec3 color = vec3(0.0);
        \\    switch (mode) {
        \\        case 0: color = vec3(1.0, 0.0, 0.0); break;
        \\        case 1: {
        \\            int sub = int(gl_FragCoord.y) % 2;
        \\            switch (sub) {
        \\                case 0: color = vec3(0.0, 1.0, 0.0); break;
        \\                default: color = vec3(0.0, 0.0, 1.0); break;
        \\            }
        \\            break;
        \\        }
        \\        default: color = vec3(0.5); break;
        \\    }
        \\    fragColor = vec4(color, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "SelectionMerge") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "LoopMerge") == null);
}

test "wgsl: QCOM block-match errors honestly (WGSL has no QCOM image ops)" {
    // GL_QCOM_image_processing block-match has no WGSL equivalent. glslpp must
    // fail loud instead of falling through to the `var v: T;` placeholder, which
    // produces silent-wrong WGSL that naga rejects ("redefinition of `v`").
    const source =
        \\#version 450
        \\#extension GL_QCOM_image_processing : require
        \\precision highp float;
        \\layout(location = 0) in vec4 v_texcoord;
        \\layout(location = 0) out vec4 fragColor;
        \\layout(set = 0, binding = 0) uniform sampler2D target_samp;
        \\layout(set = 0, binding = 1) uniform sampler2D ref_samp;
        \\void main() {
        \\    uvec2 t = uvec2(v_texcoord.xy);
        \\    uvec2 r = uvec2(v_texcoord.zw);
        \\    fragColor = textureBlockMatchSADQCOM(target_samp, t, ref_samp, r, uvec2(4, 4));
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "QCOM") != null);
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

test "wgsl: gl_VertexIndex/gl_InstanceIndex emit u32 @builtin with i32 conversion" {
    // WGSL mandates u32 for vertex_index/instance_index, but glslang types them
    // as signed i32. Emitting i32 makes naga reject the entry point. We emit a
    // u32 parameter and a converting `let ...: i32 = i32(...)` for body uses.
    const source =
        \\#version 450
        \\layout(location=0) out vec4 col;
        \\void main() {
        \\    gl_Position = vec4(float(gl_VertexIndex), float(gl_InstanceIndex), 0.0, 1.0);
        \\    col = vec4(1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@builtin(vertex_index) gl_VertexIndex_b: u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@builtin(instance_index) gl_InstanceIndex_b: u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "let gl_VertexIndex: i32 = i32(gl_VertexIndex_b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "let gl_InstanceIndex: i32 = i32(gl_InstanceIndex_b);") != null);
    // The invalid signed builtin must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@builtin(vertex_index) gl_VertexIndex: i32") == null);
}

test "wgsl: passthrough fragment store emits a defined return identifier (not freed-memory garbage)" {
    // Regression: `o = vIn` (and `o = -(-vIn)` after double-negate folding)
    // feeds an OpLoad whose result emitBody inlines to the source name (`vIn`)
    // and never emits as a `let`. The direct-return optimization captured the
    // load's *pre-emitBody* generated name (`v6`), producing `return v6;` where
    // v6 is undefined — and worse, an aliased+freed slice surfaced as
    // `return \xAA\xAA;` (freed-memory fill). Both are silent-wrong; naga rejects.
    const passthrough: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 vIn;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vIn; }
    ;
    const double_negate: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 vIn;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = -(-vIn); }
    ;
    inline for (.{ passthrough, double_negate }) |source| {
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
        defer alloc.free(spirv);
        const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
        defer alloc.free(wgsl);
        // The return value must be the in-scope input identifier, never an
        // undefined generated name or freed-memory bytes.
        try std.testing.expect(std.mem.indexOf(u8, wgsl, "return vIn;") != null);
        // The freed-memory fill byte (0xAA) must never appear: it is the
        // signature of the use-after-free this guards against. (The header
        // comment legitimately contains a UTF-8 `→`, so a blanket ASCII-only
        // check would be wrong.)
        for (wgsl) |c| try std.testing.expect(c != 0xAA);
    }
}

test "wgsl: MRT passthrough stores emit defined identifiers (not freed-memory garbage)" {
    // Same hazard as the single-output direct return, but on the multi-render-
    // target path: `o0 = vIn; o1 = vIn;` captured each stored value's name
    // pre-emitBody, surfacing as `return FragmentOutput(\xAA\xAA, \xAA\xAA);`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 vIn;
        \\layout(location=0) out vec4 o0;
        \\layout(location=1) out vec4 o1;
        \\void main(){ o0 = vIn; o1 = vIn; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "return FragmentOutput(vIn, vIn);") != null);
    for (wgsl) |c| try std.testing.expect(c != 0xAA);
}

test "wgsl: gl_FragDepth passthrough store emits a defined identifier (not freed-memory garbage)" {
    // The frag-depth return path shared the same pre-emitBody name capture:
    // `gl_FragDepth = d;` (a passthrough load) surfaced as a \xAA depth operand.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in float d;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(1.0); gl_FragDepth = d; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // depth operand must be the in-scope input `d`, not an undefined name.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ", d);") != null);
    for (wgsl) |c| try std.testing.expect(c != 0xAA);
}

test "wgsl: heavily-used immutable input load inlines to its name in inline expressions" {
    // Regression: an input read in many branches (>6 uses) was NOT inlined to its
    // source name by the load-inlining pass (a `uses <= 6` cap) AND never emitted
    // as a `let`, so inline expressions referenced an undefined `vN` — e.g. a
    // nested if/else chain produced `(v9 - 0.25) * 4.0` where `v9` is never
    // declared (naga: "no definition in scope for identifier: `v9`").
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float result;
        \\    if (u < 0.25) { result = u * 4.0; }
        \\    else if (u < 0.5) { result = 1.0 - (u - 0.25) * 4.0; }
        \\    else if (u < 0.75) { result = (u - 0.5) * 4.0; }
        \\    else { result = 1.0 - (u - 0.75) * 4.0; }
        \\    fragColor = vec4(result, result * 0.5, result * 0.25, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The immutable input `u` must appear in the arithmetic; no undefined `v9`.
    // (Scalar float constants are now typed with an `f` suffix — #170 G5 Pass 2 —
    // so the literal renders as `0.25f`.)
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "(u - 0.25f)") != null);
    // No bare reference to an undefined load temp like `v9 ` (the input is `u`).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "v9 -") == null);
    for (wgsl) |c| try std.testing.expect(c != 0xAA);
}

test "wgsl: direct recursion is an honest error (WGSL forbids recursion)" {
    // WGSL disallows any call-graph cycle. A recursive function must fail loud,
    // not emit a self-calling WGSL function that naga rejects.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\int fib(int n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }
        \\void main(){ o = vec4(float(fib(5))); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedRecursion, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: non-recursive nested function calls still compile (no false recursion flag)" {
    // Guard against the recursion detector over-firing on a normal call chain.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\vec2 inner(vec2 p) { return p * 2.0; }
        \\vec2 outer(vec2 p) { return inner(p) + p; }
        \\void main(){ o = vec4(outer(uv), 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(wgsl.len > 0);
}

// Naming-independent scope check: every `vN` temp referenced in the WGSL must be
// declared somewhere (let/var). Catches the undefined-identifier silent-wrong
// class — e.g. a loop-carried phi update leaking into a later loop where its
// value temp is out of scope (`v18 = v23` with v23 never declared).
fn assertNoUndeclaredVTemp(wgsl: []const u8) !void {
    const isIdent = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_';
        }
    }.f;
    var declared = std.StringHashMap(void).init(alloc);
    defer {
        var it = declared.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        declared.deinit();
    }
    inline for (.{ "let ", "var " }) |kw| {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, wgsl, idx, kw)) |p| {
            idx = p + kw.len;
            var e = idx;
            while (e < wgsl.len and isIdent(wgsl[e])) e += 1;
            const name = wgsl[idx..e];
            if (name.len >= 2 and name[0] == 'v' and std.ascii.isDigit(name[1])) {
                const owned = try alloc.dupe(u8, name);
                if ((try declared.fetchPut(owned, {})) != null) alloc.free(owned);
            }
        }
    }
    var i: usize = 0;
    while (i < wgsl.len) : (i += 1) {
        if (wgsl[i] != 'v') continue;
        if (i > 0 and isIdent(wgsl[i - 1])) continue;
        if (i + 1 >= wgsl.len or !std.ascii.isDigit(wgsl[i + 1])) continue;
        var e = i;
        while (e < wgsl.len and isIdent(wgsl[e])) e += 1;
        const name = wgsl[i..e];
        // A `vN:` token is a declaration site (function parameter or typed
        // binding), not a use — record it as declared and move on.
        var j = e;
        while (j < wgsl.len and wgsl[j] == ' ') j += 1;
        if (j < wgsl.len and wgsl[j] == ':') {
            if (!declared.contains(name)) {
                const owned = try alloc.dupe(u8, name);
                if ((try declared.fetchPut(owned, {})) != null) alloc.free(owned);
            }
            i = e - 1;
            continue;
        }
        if (!declared.contains(name)) {
            std.debug.print("undeclared WGSL temp referenced: {s}\n", .{name});
            return error.UndeclaredTemp;
        }
        i = e - 1;
    }
}

test "wgsl: a loop without phis does not inherit a previous loop's phi update (scope leak)" {
    // Two consecutive loops: the second must not re-emit the first's loop-carried
    // back-edge update (which references a value temp scoped to the first loop).
    // Regression for the stale `pending_phi_start` phi-range mis-attribution.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out float o;
        \\void main(){
        \\  float a = 0.0;
        \\  for (int i = 0; i < 4; i++) { a += float(i); }
        \\  int k = 0;
        \\  for (; k < 5; k++) { a += 1.0; }
        \\  o = a + float(k);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertNoUndeclaredVTemp(wgsl);
}

test "wgsl: frexp/modf emit WGSL struct-return form (not the illegal pointer form)" {
    // GLSL frexp(x, out e)/modf(x, out i) lower to GLSL.std.450 Frexp/Modf
    // (pointer form). WGSL frexp(x)/modf(x) take ONE arg and return a struct:
    // frexp -> {fract, exp}, modf -> {fract, whole}. Emitting `frexp(x, ptr)`
    // was a naga reject ("too many arguments") AND dropped the exponent.
    const source: [:0]const u8 =
        "#version 310 es\nprecision mediump float;\n" ++
        "layout(location=0) out float FragColor;\nlayout(location=0) in float v0;\n" ++
        "void main(){\n  int e0; float f0 = frexp(v0, e0);\n  float r0; float m0 = modf(v0, r0);\n  FragColor = f0 + m0 + float(e0) + r0;\n}\n";
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Struct-return fields must be used; no 2-arg builtin call.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ".fract") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ".exp") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ".whole") != null);
    try assertNoUndeclaredVTemp(wgsl);
}

test "wgsl: a stage input used in a helper function is promoted to var<private>" {
    // WGSL @location inputs are entry-point parameters, not module globals, so a
    // helper that reads one would emit an undefined identifier. The input must be
    // promoted to a module-scope var<private>, bridged from the entry parameter.
    // (spec: docs/specs/2026-06-02-wgsl-cross-function-io.md)
    const source: [:0]const u8 =
        "#version 450\n" ++
        "layout(location=0) in vec2 uv;\n" ++
        "layout(location=0) out vec4 fragColor;\n" ++
        "float effect(vec2 p) { return length(p + uv); }\n" ++
        "void main(){ fragColor = vec4(effect(vec2(0.5))); }\n";
    // NoOpt so the helper is not inlined away — guarantees a genuine
    // cross-function reference to the input for this test.
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The input is a module-scope private global, bridged from a renamed param.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<private> uv: vec2f;") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uv_in: vec2f") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uv = uv_in;") != null);
    try assertNoUndeclaredVTemp(wgsl);
}

test "wgsl: a shader with NO cross-function input is unchanged (no spurious var<private>)" {
    // Gate check: when no input is used in a helper, nothing is promoted.
    const source: [:0]const u8 =
        "#version 450\n" ++
        "layout(location=0) in vec2 uv;\n" ++
        "layout(location=0) out vec4 fragColor;\n" ++
        "void main(){ fragColor = vec4(uv, 0.0, 1.0); }\n";
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<private> uv") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uv_in") == null);
}

test "wgsl: an output read back in the body is declared as a local var (not direct-returned)" {
    // Partial writes + read-back of the output (e.g. modf.legacy's
    // `result.xy=…; result.zw=…` with `result.z` reads) must declare the output
    // as a zero-initialised `var` and return it — the direct-return optimization
    // would skip the declaration and leave the read referencing an undefined name.
    const source: [:0]const u8 =
        "#version 450\n" ++
        "layout(location=0) in vec2 v;\n" ++
        "layout(location=0) out vec4 o;\n" ++
        "void main(){ o.xy = v; o.zw = o.xy + o.zw; }\n";
    // NoOpt so the output read-back is preserved for the test.
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The output is a declared local var and is returned (not a bare reconstruction).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var o: vec4f;") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "return o;") != null);
    try nagaValidateOrSkip(wgsl, "output-readback");
}

test "wgsl: clip-distance is an honest error, not a naga-invalid @location array" {
    // gl_ClipDistance is an array<f32,N> built-in; WGSL only allows numeric
    // scalars/vectors as user entry-point I/O (naga rejects the array), and
    // glslpp previously emitted `@location(N) gl_ClipDistance: array<f32,8>`
    // — naga-invalid (silent-wrong). It must fail loud instead.
    const source: [:0]const u8 =
        \\#version 450
        \\out gl_PerVertex { vec4 gl_Position; float gl_ClipDistance[1]; };
        \\layout(location=0) in vec4 p;
        \\void main(){ gl_Position = p; gl_ClipDistance[0] = p.x; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: stage output interface block is flattened into VertexOutput" {
    // GLSL `out Block { vec4 color; vec3 normal; } vout;` -> a struct-typed
    // Output. WGSL forbids a nested struct field in an I/O struct, so the block
    // members are flattened into VertexOutput and `vout.color` becomes
    // `vertex_out.color`. glslpp emitted `@location(0) vout: Block` (undeclared
    // nested struct) → naga "no definition in scope".
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 Position;
        \\out Block { vec4 color; vec3 normal; } vout;
        \\void main(){ gl_Position = Position; vout.color = vec4(1.0); vout.normal = vec3(0.5); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(0) color: vec4f") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(1) normal: vec3f") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vertex_out.color =") != null);
    // No nested struct field.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ": Block") == null);
    try nagaValidateOrSkip(wgsl, "io-block-output");
}

test "wgsl: stage input interface block is declared as a struct with @location members" {
    // GLSL `in Block { flat float f; vec4 g; int h; } vin;` -> a struct-typed
    // Input variable. WGSL needs a struct with @location/@interpolate members
    // passed by value; glslpp emitted `@location(0) vin: Block` with the struct
    // undeclared (naga: "no definition in scope for identifier: Block").
    const source: [:0]const u8 =
        \\#version 450
        \\in Block { flat float f; vec4 g; flat int h; } vin;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(vin.f) + vin.g + vec4(float(vin.h)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "struct Block {") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(0) f: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(2) @interpolate(flat) h: i32") != null);
    // The param is a bare struct (members carry @location), not @location(N) vin.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vin: Block") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(0) vin") == null);
    try nagaValidateOrSkip(wgsl, "io-block-input");
}

test "wgsl: struct constructed from vector components keeps per-field args" {
    // `Point(uv.x, uv.y)` must stay per-field; the vector-collapse simplification
    // (valid for `vec2(uv.x,uv.y)->uv`) wrongly produced `Point(uv)` — a vec2
    // passed to a 2-scalar struct, which naga rejects.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\struct P { float a; float b; };
        \\void main(){ P p = P(uv.x, uv.y); o = vec4(p.a, p.b, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "(uv.x, uv.y)") != null);
    try nagaValidateOrSkip(wgsl, "struct-from-vec");
}

test "wgsl: dual-source blending (two outputs at one @location) is an honest error" {
    // GLSL `layout(location=0, index=0/1)` dual-source blending → WGSL needs
    // @blend_src, but glslpp's SPIR-V drops the Index decoration, so the backend
    // can't tell src0 from src1. Emitting two @location(0) is naga-invalid
    // ("Multiple bindings at location 0"); fail loud instead.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0, index=0) out vec4 c0;
        \\layout(location=0, index=1) out vec4 c1;
        \\void main(){ c0 = vec4(1.0); c1 = vec4(2.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: depth-only fragment declares -> FragmentOutput return type" {
    // A shader writing only gl_FragDepth (no color output) returns
    // `FragmentOutput(...)` from its body, so the signature must declare the
    // return type. glslpp emitted `fn main()` (no return type) because
    // output_var_id was null → naga "Returning Some where None is expected".
    const source: [:0]const u8 =
        \\#version 450
        \\layout(depth_greater) out float gl_FragDepth;
        \\void main(){ gl_FragDepth = 0.5; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "-> FragmentOutput") != null);
    try nagaValidateOrSkip(wgsl, "depth-only");
}

test "wgsl: vector shift coerces the amount to vecN<u32>, not scalar u32" {
    // `uvec2(1) << uvec2(a,b)` — the WGSL shift amount must match the base's
    // vector dimension (`vec2<u32> << vec2<u32>`). glslpp wrapped it in scalar
    // `u32(...)` ("cannot cast a vec2<u32> to a u32"); scalar shifts keep `u32()`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) flat in uvec2 a;
        \\layout(location=0) out uvec2 o;
        \\void main(){ o = (uvec2(1u) << a) - 1u; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vec2<u32>(") != null);
    try nagaValidateOrSkip(wgsl, "vec-shift");
}

test "wgsl: scalar geometric builtins lower to scalar ops (normalize->sign etc.)" {
    // GLSL allows normalize/length/distance on scalars; WGSL defines them only on
    // vectors (naga: "wrong type passed as argument #1 to `normalize`"). They must
    // lower: normalize(x)->sign(x), length(x)->abs(x), distance(a,b)->abs(a-b).
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { float a; float b; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(normalize(u.a), length(u.a), distance(u.a, u.b), 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "sign(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "abs(") != null);
    // The vector-only builtins must NOT be emitted on scalars.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "normalize(") == null);
    try nagaValidateOrSkip(wgsl, "scalar-geom");
}

test "wgsl: scalar refract is an honest error (vector-only builtin, formula not faked)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { float i; float n; float e; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(refract(u.i, u.n, u.e)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: gl_PointSize is an honest error, not @builtin(__point_size)" {
    // WGSL points always render at 1px — there is no point-size output. glslpp
    // previously emitted `@builtin(__point_size)` (an invented builtin) which
    // naga rejects ("Identifier starts with a reserved prefix: `__point_size`").
    // The PointSize decoration only appears when the shader actually writes
    // gl_PointSize, so failing loud is correct: WGSL cannot honor the size.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 p;
        \\void main(){ gl_Position = p; gl_PointSize = 4.0; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: constant array of vectors uses array<vecN<T>,M>, not the scalar elem type" {
    // A `const vec3 pal[3]` lowered to an OpConstantComposite array previously
    // emitted `array<f32, 3>(vec3<f32>(...), ...)` — the element type was the
    // vector's SCALAR, a type mismatch naga rejects. The element must be the
    // full `vec3<f32>`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\    const vec3 pal[4] = vec3[4](vec3(1.0,0.0,0.0), vec3(0.0,1.0,0.0), vec3(0.0,0.0,1.0), vec3(1.0,1.0,0.0));
        \\    int idx = clamp(int(gl_FragCoord.x) / 64, 0, 3);
        \\    o = vec4(pal[idx], 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Element type is the vector (vec3f / vec3<f32>), never a bare scalar array.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "array<vec3") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "array<f32, 4>(") == null);
    try nagaValidateOrSkip(wgsl, "const-array-of-vec");
}

test "wgsl: constant array of structs uses array<StructName,N> element type" {
    // Extends the array-of-vectors fix to STRUCT (and nested-array) elements: an
    // `OpConstantComposite` array of structs previously emitted
    // `array<f32, 2>(Foobar(...), ...)` — scalar element type, a mismatch naga
    // rejects. The element must be the struct name `Foobar`.
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location=0) out vec4 o;
        \\struct Foobar { float a; float b; };
        \\void main(){
        \\    const Foobar foos[2] = Foobar[](Foobar(10.0, 40.0), Foobar(90.0, 70.0));
        \\    o = vec4(foos[0].a + foos[1].b);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "array<Foobar, 2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "array<f32, 2>(Foobar") == null);
    try nagaValidateOrSkip(wgsl, "const-array-of-struct");
}

test "wgsl: array element extract uses [i] indexing, not a .x swizzle" {
    // OpCompositeExtract of an array element (`arr[0]`) was inlined as `arr.x`
    // — a vector swizzle on an array — which naga rejects ("invalid field
    // accessor `x`"). Covers both a named local array and an inline constant
    // array literal (`array<vec4<f32>,2>(...)[0]`).
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\layout(location=0) in vec4 a;
        \\void main(){
        \\    vec4 vals[2] = vec4[2](a, a + vec4(1.0));
        \\    vec4 consts[2] = vec4[2](vec4(10.0), vec4(30.0));
        \\    o = vals[0] + vals[1] + consts[0];
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "array-extract-index");
}

test "wgsl: module-scope const array indexed at runtime emits its values" {
    // Regression: a `const T arr[N]` global indexed by a runtime value lowers to
    // a Private OpVariable carrying a constant-composite initializer. The "used"
    // check ignored OpAccessChain, so the declaration was skipped (`arr[i]`
    // referenced an undeclared name); and resolveConstantExpr didn't build array
    // literals, so even when declared it fell back to a zero-init var<private>
    // (wrong values = silent-wrong). Now: `const LUT: array<f32,4> =
    // array<f32,4>(1.0, 2.0, 3.0, 4.0);` and the access resolves to it. Index by
    // int(gl_FragCoord.x) to avoid the orthogonal integer-`flat`-input concern.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out float o;
        \\const float LUT[4] = float[](1.0, 2.0, 3.0, 4.0);
        \\void main(){ int i = int(gl_FragCoord.x) & 3; o = LUT[i]; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "array<f32, 4>(1.0, 2.0, 3.0, 4.0)");
    try assertNotContains(wgsl, "var<private> LUT"); // not a zero-init fallback
    try nagaValidateOrSkip(wgsl, "const-array-global");
}

test "wgsl: a reloaded input index keeps one name across recomputed sub-expressions" {
    // Regression (spirv-cross constant-array.frag / lut-promotion.frag): the
    // single load of a `flat in int index` is rendered INCONSISTENTLY — as the
    // input name `index` in the direct emission path but as its raw generated
    // `vN` inside a sub-expression that the running sum gets recomputed into
    // (triggered by re-evaluating function-call arguments). The recomputed `vN`
    // was never declared → naga "no definition in scope".
    //
    // Root cause: the AccessChain pre-scan froze the index operand using the
    // load's default name BEFORE the immutable-load name propagation ran, so the
    // inline expressions captured `v20` while direct emission used `index`. The
    // fix propagates immutable direct-variable load names before the AccessChain
    // pre-scan so a reloaded value is bound consistently everywhere.
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out vec4 FragColor;
        \\layout(location = 0) flat in int index;
        \\struct Foobar { float a; float b; };
        \\vec4 resolve(Foobar f) { return vec4(f.a + f.b); }
        \\void main() {
        \\   const vec4 foo[3] = vec4[](vec4(1.0), vec4(2.0), vec4(3.0));
        \\   const vec4 foobars[2][2] = vec4[][](vec4[](vec4(1.0), vec4(2.0)), vec4[](vec4(8.0), vec4(10.0)));
        \\   const Foobar foos[2] = Foobar[](Foobar(10.0, 40.0), Foobar(90.0, 70.0));
        \\   FragColor = foo[index] + foobars[index][index + 1] + resolve(Foobar(10.0, 20.0)) + resolve(foos[index]);
        \\}
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertNoUndeclaredVTemp(wgsl);
    try nagaValidateOrSkip(wgsl, "reloaded-index-def-drop");
}

test "wgsl: a reloaded output accumulator keeps one name across recomputed sub-expressions" {
    // Regression (spirv-cross lut-promotion.frag): the same def-drop class as the
    // index case, but for a reloaded OUTPUT. Successive `FragColor += …` reload
    // the output; a sub-expression recomputed into a later `+` froze the
    // `OpLoad %FragColor` as its raw `vN` (the is_output_load name propagation
    // only ran at emission, after the inline-expression pre-scan) → undeclared
    // `vN` (naga "no definition in scope"). The fix propagates output/input/
    // texture load names before the pre-scans.
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out float FragColor;
        \\layout(location = 0) flat in int index;
        \\const float LUT[16] = float[](
        \\    1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 4.0,
        \\    1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 4.0);
        \\void main() {
        \\    FragColor = LUT[index];
        \\    if (index < 10) FragColor += LUT[index ^ 1];
        \\    else FragColor += LUT[index & 1];
        \\    vec4 foo[4] = vec4[](vec4(0.0), vec4(1.0), vec4(8.0), vec4(5.0));
        \\    if (index > 30) FragColor += foo[index & 3].y;
        \\    else FragColor += foo[index & 1].x;
        \\    vec4 foobar[4] = vec4[](vec4(0.0), vec4(1.0), vec4(8.0), vec4(5.0));
        \\    if (index > 30) foobar[1].z = 20.0;
        \\    FragColor += foobar[index & 3].z;
        \\    vec4 baz[4] = vec4[](vec4(0.0), vec4(1.0), vec4(8.0), vec4(5.0));
        \\    baz = vec4[](vec4(20.0), vec4(30.0), vec4(50.0), vec4(60.0));
        \\    FragColor += baz[index & 3].z;
        \\}
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertNoUndeclaredVTemp(wgsl);
    try nagaValidateOrSkip(wgsl, "reloaded-output-def-drop");
}

// --- gap #170 Pass 1: deepen WGSL coverage ---------------------------------

test "wgsl: findMSB(uint) lowers to firstLeadingBit (GLSL.std.450 FindUMsb 75)" {
    // GLSL findMSB on an unsigned int emits GLSL.std.450 FindUMsb (75). It was
    // missing from the shared name table, so it hit recordUnsupportedExtInst —
    // a needless honest-error for an op WGSL fully supports as firstLeadingBit.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { uint a; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ uint m = uint(findMSB(u.a)); o = vec4(float(m)); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "firstLeadingBit(");
    try nagaValidateOrSkip(wgsl, "findMSB-uint");
}

// textureProj semantics: divide the coordinate by its LAST component, then
// sample with the leading components matching the sampler dimensionality. WGSL
// has no projective builtin, but the perspective divide + plain textureSample is
// a CORRECT, naga-validated lowering for the non-Dref forms — so emit it
// (dimension-aware), rather than blanket honest-erroring (which regressed the
// working 2D case). Dref/compare projective forms stay honest-errored.
test "wgsl: textureProj(sampler2D, vec4) lowers to coord.xy / coord.w" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProj(tex, vec4(gl_FragCoord.xy, 0.0, 1.0)); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSample(");
    try assertContains(wgsl, ".xy / ");
    try assertContains(wgsl, ".w");
    try nagaValidateOrSkip(wgsl, "textureProj-2d-vec4");
}

test "wgsl: textureProj(sampler2D, vec3) divides by the LAST component (.z)" {
    // The vec3 form's divisor is the LAST component (.z), not .w. The old
    // handler emitted `.w` on a vec3 (out-of-bounds / wrong) — this is the
    // dimension-aware fix.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProj(tex, vec3(gl_FragCoord.xy, 1.0)); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSample(");
    try assertContains(wgsl, ".xy / ");
    try assertContains(wgsl, ".z");
    try nagaValidateOrSkip(wgsl, "textureProj-2d-vec3");
}

test "wgsl: textureProj(sampler3D, vec4) lowers to coord.xyz / coord.w" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler3D tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProj(tex, vec4(gl_FragCoord.xyz, 1.0)); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSample(");
    try assertContains(wgsl, ".xyz / ");
    try assertContains(wgsl, ".w");
    try nagaValidateOrSkip(wgsl, "textureProj-3d-vec4");
}

test "wgsl: projective shadow (sampler2DShadow) is an honest error" {
    // Projective depth-compare has no clean WGSL mapping (textureSampleCompare
    // takes no projective coord and the divided ref is value-sensitive). Fail
    // loud rather than silently drop the depth compare.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow tex;
        \\layout(location=0) out float o;
        \\void main(){ o = textureProj(tex, vec4(gl_FragCoord.xy, 0.5, 1.0)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: fragment-shader interlock is an honest error (no WGSL equivalent)" {
    // GL_ARB_fragment_shader_interlock emits OpBeginInvocationInterlockEXT /
    // OpEndInvocationInterlockEXT (and an interlock execution mode). WGSL has no
    // fragment-shader interlock; fail loud rather than silently drop the barrier.
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_ARB_fragment_shader_interlock : require
        \\layout(pixel_interlock_ordered) in;
        \\layout(binding=0, std430) buffer B { uint counter; };
        \\layout(location=0) out vec4 o;
        \\void main(){ beginInvocationInterlockARB(); counter += 1u; endInvocationInterlockARB(); o = vec4(1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: the main-path else no longer emits a silent-wrong placeholder var" {
    // Regression guard for the silent-wrong `else` fallback. It used to emit
    // `// unhandled op N` + `var <name>: T;` (an uninitialized var = garbage value
    // that naga still accepts). A representative shader exercising many ops must
    // compile WITHOUT any such placeholder, and naga must accept the real output.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { vec4 a; vec4 b; uint n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\    vec4 m = mix(u.a, u.b, 0.5);
        \\    uint bits = uint(findMSB(u.n)) + uint(findLSB(u.n));
        \\    o = m + vec4(float(bits)) + vec4(min(u.a.x, u.b.x), max(u.a.y, u.b.y), clamp(u.a.z, 0.0, 1.0), 1.0);
        \\}
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertNotContains(wgsl, "unhandled op");
    try nagaValidateOrSkip(wgsl, "no-silent-placeholder");
}

test "wgsl: matrix-element const-array global folds to an mat4x4 array initializer (#173 item1)" {
    // #173 item1: `const mat4 M[2]` runtime-indexed. The frontend now folds the
    // matrix ctors + the array ctor to OpConstantComposite, so M carries an
    // initializer the WGSL backend materializes as an `array<mat4x4f, 2>(...)`
    // (or const) — not an undeclared/garbage global. naga is the ground truth.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 FragColor;
        \\const mat4 M[2] = mat4[](mat4(1.0), mat4(2.0));
        \\void main(){
        \\  int i = int(gl_FragCoord.x) & 1;
        \\  FragColor = M[i] * vec4(1.0);
        \\}
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    // The array is materialized as a mat4x4 array with an initializer (the exact
    // var<private>/const spelling may vary). Assert the constructor SHAPE with the
    // folded diagonal values (like the MSL test asserts `float4x4(float4(…))`), not
    // just a bare "2.0" substring — proves the matrix ctors actually folded.
    try assertContains(wgsl, "array<mat4x4");
    try assertContains(wgsl, "mat4x4f(vec4f(1.0, 0.0, 0.0, 0.0)");
    try assertContains(wgsl, "mat4x4f(vec4f(2.0, 0.0, 0.0, 0.0)");
    try nagaValidateOrSkip(wgsl, "matrix-const-array-#173");
}

// ---------------------------------------------------------------------------
// Pass 2 (#170 G5): OpOuterProduct → matrix construction.
// outerProduct(u, v) (u is an R-vector, v is a C-vector) yields a CxR matrix
// whose column i is u*v[i]. WGSL has no outerProduct builtin; the backend must
// construct the matrix explicitly. Previously OpOuterProduct fell through to the
// honest-error else-arm. naga is the ground truth.
// ---------------------------------------------------------------------------

test "wgsl: outerProduct(vec3,vec3) builds a mat3x3 (naga-validated)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec3 a;
        \\layout(location=1) in vec3 b;
        \\layout(location=0) out vec4 o;
        \\void main(){ mat3 m = outerProduct(a, b); o = vec4(m[0], 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "mat3x3") != null);
    try nagaValidateOrSkip(wgsl, "outerProduct-mat3");
}

test "wgsl: outerProduct(vec2,vec2) builds a mat2x2 (naga-validated)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec2 a;
        \\layout(location=1) in vec2 b;
        \\layout(location=0) out vec4 o;
        \\void main(){ mat2 m = outerProduct(a, b); o = vec4(m[0], m[1]); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "mat2x2") != null);
    try nagaValidateOrSkip(wgsl, "outerProduct-mat2");
}

test "wgsl: outerProduct(vec4,vec2) builds a non-square mat2x4 (naga-validated)" {
    // u is a 4-vector (rows), v is a 2-vector (cols) → a 2-column, 4-row matrix
    // (WGSL mat2x4). The result has v's column count and u's row count.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 a;
        \\layout(location=1) in vec2 b;
        \\layout(location=0) out vec4 o;
        \\void main(){ mat2x4 m = outerProduct(a, b); o = m[0] + m[1]; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "mat2x4") != null);
    try nagaValidateOrSkip(wgsl, "outerProduct-mat2x4");
}

// ---------------------------------------------------------------------------
// Pass 2 (#170 G5): abstract scalar-literal typing.
// naga rejects all-constant-arg builtin calls (e.g. smoothstep(0.08, 0.03, 1.0))
// with "Abstract types may only appear in constant expressions". Suffixing scalar
// float constants with `f` types them concretely, which naga accepts.
// ---------------------------------------------------------------------------

test "wgsl: all-constant smoothstep is naga-valid (abstract-literal typing)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ float t = smoothstep(0.08, 0.03, 1.0); o = vec4(t); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // A scalar float constant must be typed (e.g. `0.08f`) rather than abstract.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "0.08f") != null);
    try nagaValidateOrSkip(wgsl, "abstract-smoothstep");
}

test "wgsl: all-constant mix is naga-valid (abstract-literal typing)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ float t = mix(0.25, 0.75, 0.5); o = vec4(t); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "abstract-mix");
}

// ---------------------------------------------------------------------------
// Pass 2 (#170 G5) AUDIT FIX: subgroup ops were emitted directly (e.g.
// subgroupElect()) with NO `enable subgroups;`. naga 29.0.3 rejects subgroups
// entirely, so this was silent-wrong. They must now honest-error.
// ---------------------------------------------------------------------------

test "wgsl: subgroupElect errors honestly (WGSL/naga has no subgroups)" {
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_KHR_shader_subgroup_basic : require
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(subgroupElect() ? 1.0 : 0.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "subgroup") != null);
}

// ---------------------------------------------------------------------------
// Pass 2 (#170 G5) AUDIT FIX: image atomics emitted atomicAdd(&textureLoad(...))
// which naga rejects ("operand of & must be a reference"). WGSL has no image
// atomics; the OpAtomic* handler must honest-error when the pointer resolves to
// an image / textureLoad.
// ---------------------------------------------------------------------------

test "wgsl: image atomic errors honestly (WGSL has no image atomics)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, r32ui) uniform uimage2D img;
        \\layout(location=0) out vec4 o;
        \\void main(){ uint old = imageAtomicAdd(img, ivec2(0,0), 1u); o = vec4(float(old)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "image atomic") != null);
}

// ---------------------------------------------------------------------------
// Pass 3 (#170 G5) ITEM A1: push-constant blocks. SPIR-V StorageClass
// PushConstant was unhandled (fell into the switch `else`), so the struct type
// and the `push` var were never emitted while the body still referenced
// `push.a` → naga "no definition in scope for push". WGSL has no push_constant
// address space (naga 29.0.3 rejects both `var<push_constant>` and
// `enable push_constant`); the representable lowering is a uniform buffer.
// ---------------------------------------------------------------------------

test "wgsl: push_constant block lowers to var<uniform>" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(push_constant) uniform PC { vec4 a; vec4 b; } push;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = push.a + push.b; }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    // The push-constant block must materialise as a uniform buffer + struct, not
    // vanish (which left `push.a` dangling).
    try assertContains(wgsl, "var<uniform>");
    try assertContains(wgsl, "struct");
    try nagaValidateOrSkip(wgsl, "push-constant-as-uniform");
}

// ---------------------------------------------------------------------------
// Pass 3 (#170 G5) ITEM H: texel buffers. An OpTypeImage with Dim=Buffer
// (GLSL samplerBuffer/imageBuffer) was emitted as `texture_buffer<f32>`, which
// is NOT standard WGSL — naga rejects it (silent-wrong-shaped emission). WGSL
// has no texel-buffer type, so it must honest-error.
// ---------------------------------------------------------------------------

test "wgsl: texel buffer errors honestly (WGSL has no texture_buffer type)" {
    const source: [:0]const u8 =
        \\#version 310 es
        \\#extension GL_OES_texture_buffer : require
        \\layout(binding = 4) uniform highp samplerBuffer uSamp;
        \\void main(){ gl_Position = texelFetch(uSamp, 10); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "texel buffer") != null);
}

// ---------------------------------------------------------------------------
// Pass 4 (#170 G5) sub-bucket A2: array-member-in-uniform stride.
// A uniform (std140) block with a scalar- or vec2-element array member emits
// `array<f32,N>` (stride 4) / `array<vec2<f32>,N>` (stride 8). WGSL's uniform
// address space requires every array element stride to be a multiple of 16, so
// naga REJECTS: "array stride 4 is not a multiple of the required alignment 16".
// `@stride` is not valid WGSL, so the only portable lowering is to widen the
// element to a vec4 and swizzle on access: `arr: array<vec4<f32>,N>` + `.x`.
// vec4/mat array members are already 16-aligned and must NOT be wrapped.
// Storage (SSBO) tolerates stride 4 → UNIFORM-ONLY.
// ---------------------------------------------------------------------------

test "wgsl: A2 scalar array member in uniform wrapped as array<vec4>+.x" {
    // RED (before fix): naga "array stride 4 is not a multiple of the required
    //  alignment 16" on `arr: array<f32, 4>`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { float arr[4]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.arr[u.n], 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The scalar-element array member is widened to vec4<f32>.
    try assertContains(wgsl, "array<vec4<f32>, 4>");
    // Access site swizzles the widened element back to a scalar.
    try assertContains(wgsl, ".x");
    try nagaValidateOrSkip(wgsl, "A2-scalar-array");
}

test "wgsl: A2 vec2 array member in uniform wrapped as array<vec4>+.xy" {
    // RED (before fix): naga "array stride 8 is not a multiple of the required
    //  alignment 16" on `arr: array<vec2<f32>, 4>`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { vec2 arr[4]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.arr[u.n], 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "array<vec4<f32>, 4>");
    try assertContains(wgsl, ".xy");
    try nagaValidateOrSkip(wgsl, "A2-vec2-array");
}

test "wgsl: A2 mixed block — scalar array wrapped, vec4 array NOT wrapped" {
    // A block mixing a sub-16 scalar array (must wrap+.x) with already-16-aligned
    // members (mat4, vec4 array, vec4 scalar) which must be emitted verbatim.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U {
        \\  float sarr[3];
        \\  mat4 m;
        \\  vec4 v4[2];
        \\  vec4 off;
        \\  int n;
        \\} u;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  o = vec4(u.sarr[u.n], 0.0, 0.0, 1.0) + u.m[0] + u.v4[u.n] + u.off;
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The scalar array member is widened to vec4<f32>.
    try assertContains(wgsl, "array<vec4<f32>, 3>");
    // The vec4 array member stays the normal shorthand (already 16-aligned).
    try assertContains(wgsl, "v4: array<vec4f, 2>");
    // It must NOT be re-widened, and its access must NOT carry a stray swizzle.
    try assertNotContains(wgsl, "v4: array<vec4<f32>, 2>");
    try assertNotContains(wgsl, "v4[u.n].x");
    try nagaValidateOrSkip(wgsl, "A2-mixed");
}

test "wgsl: A2 regression — array-of-vec4 uniform stays unwrapped, no swizzle" {
    // Over-wrap guard: a vec4 array member is already 16-aligned and must be
    // emitted as array<vec4<f32>,3> with NO appended swizzle on access.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { vec4 a[3]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = u.a[u.n]; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Already-aligned vec4 array stays the normal shorthand (NOT re-widened).
    try assertContains(wgsl, "array<vec4f, 3>");
    try assertNotContains(wgsl, "array<vec4<f32>, 3>");
    // No swizzle should be appended to the vec4-array access.
    try assertNotContains(wgsl, "a[u.n].x");
    try nagaValidateOrSkip(wgsl, "A2-vec4-array");
}

test "wgsl: A2 SSBO scalar array member NOT wrapped (uniform-only gate)" {
    // Gate guard: storage buffers tolerate stride 4, so an SSBO scalar array
    // member must stay array<f32,4> with no swizzle.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std430) buffer B { float arr[4]; int n; } b;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(b.arr[b.n], 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // SSBO scalar array stays a plain f32 array — NOT widened.
    try assertContains(wgsl, "array<f32, 4>");
    try assertNotContains(wgsl, "arr: array<vec4<f32>, 4>");
    try nagaValidateOrSkip(wgsl, "A2-ssbo-scalar-array");
}

// ---------------------------------------------------------------------------
// #170 review — wrap must gate on ArrayStride == 16, NOT just !is_ssbo.
//
// The vec4-wrap (`array<vec4<f32>,N>` + `.x`) is only VALUE-CORRECT when the
// source array's std140 ArrayStride is 16: std140 rounds every array-element
// stride up to 16, so the host packs the float at byte 0 of each 16-byte slot,
// exactly where `arr[i].x` reads it. A scalar-block-layout / std430 UNIFORM
// has ArrayStride 4 (host packs floats tightly at 0,4,8,12); the vec4-wrap then
// reads bytes 0,16,32,48 → WRONG DATA, yet naga ACCEPTS it (silent-wrong).
//
// On `main` this same shader emitted `array<f32,4>` (stride 4) which naga
// REJECTS loudly ("array stride 4 is not a multiple of the required alignment
// 16") — an HONEST failure. The fix gates the wrap on ArrayStride==16 so the
// scalar-layout case falls through to the honest (naga-rejected) path instead
// of being silently wrapped wrong.
// ---------------------------------------------------------------------------

test "wgsl: A2 scalar-block-layout uniform NOT silently wrapped (#170 review)" {
    // The MAJOR silent-wrong guard. The source SPIR-V has ArrayStride 4 (verified
    // out-of-band via spirv-dis: `OpDecorate %_arr_float_uint_4 ArrayStride 4`),
    // so wrapping to `array<vec4<f32>>` + `.x` would read the wrong host bytes.
    //
    // RED (pre-fix): emits `arr: array<vec4<f32>, 4>` + `u.arr[u.n].x` — accepted
    //   by naga but reads bytes 0,16,32,48 instead of 0,4,8,12 = SILENT-WRONG.
    // GREEN (post-fix): the member is NOT recorded for wrapping (stride != 16), so
    //   it falls through to the honest `array<f32, 4>` path which naga REJECTS
    //   loudly (matching main). We assert the absence of the vec4-wrap — proving
    //   we did not silent-wrong it. This case is intentionally honest-rejected by
    //   naga (like main), so it is NOT naga-validated as passing here.
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_EXT_scalar_block_layout : require
        \\layout(binding=0, scalar) uniform U { float arr[4]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.arr[u.n], 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The stride-4 array member must NOT be silently widened to vec4.
    try assertNotContains(wgsl, "array<vec4<f32>, 4>");
    try assertNotContains(wgsl, "u.arr[u.n].x");
    // It falls through to the honest (naga-rejected) plain-f32 array.
    try assertContains(wgsl, "array<f32, 4>");
}

test "wgsl: A2 std140 uniform still wraps at ArrayStride 16 (#170 review regression)" {
    // Regression for the stride gate: an std140 uniform float-array member has
    // ArrayStride 16 (verified: `OpDecorate %_arr_float_uint_4 ArrayStride 16`),
    // so it MUST still be wrapped to `array<vec4<f32>>` + `.x` and naga-validate.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { float arr[4]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.arr[u.n], 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // std140 stride 16 → still widened + swizzled (value-correct).
    try assertContains(wgsl, "array<vec4<f32>, 4>");
    try assertContains(wgsl, ".x");
    try nagaValidateOrSkip(wgsl, "A2-std140-stride16-wrap");
}
