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
