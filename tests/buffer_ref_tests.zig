// SPDX-License-Identifier: MIT OR Apache-2.0
// M8.2: GL_EXT_buffer_reference — preprocessor recognition.
//
// The buffer-reference syntax and SPIR-V codegen are already implemented in
// the parser/IR. This test suite locks in that the preprocessor accepts the
// `#extension GL_EXT_buffer_reference : require` directive (previously
// silently rejected because the name wasn't in the known-extension list).
const std = @import("std");
const glslpp = @import("glslpp");

test "buffer_reference: extension is recognized and compiles" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_buffer_reference : require
        \\layout(buffer_reference, std430) readonly buffer FloatRef {
        \\    float v;
        \\};
        \\layout(set=0, binding=0) uniform U { FloatRef ref; } u;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(u.ref.v); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spv.len >= 5);
    try std.testing.expectEqual(@as(u32, glslpp.spirv.MAGIC), spv[0]);
}

test "buffer_reference: GL_EXT_buffer_reference define is set" {
    // After recognition, the preprocessor injects a `#define GL_EXT_buffer_reference 1`.
    // Smoke-test by using the define in an #ifdef.
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_buffer_reference : require
        \\#ifdef GL_EXT_buffer_reference
        \\layout(buffer_reference, std430) readonly buffer FloatRef { float v; };
        \\layout(set=0, binding=0) uniform U { FloatRef ref; } u;
        \\#endif
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(u.ref.v); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    try std.testing.expect(spv.len >= 5);
}

// M8.5 regression: the buffer_reference shader uses a struct member literally
// called `ref`, which is a reserved word in WGSL
// (https://www.w3.org/TR/WGSL/#reserved-words). The WGSL backend must rename
// it; otherwise naga rejects the output with "name `ref` is a reserved keyword".
test "buffer_reference WGSL backend escapes ref reserved keyword" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\#extension GL_EXT_buffer_reference : require
        \\layout(buffer_reference, std430) readonly buffer FloatRef { float v; };
        \\layout(set=0, binding=0) uniform U { FloatRef ref; } u;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = vec4(u.ref.v); }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);

    const wgsl = try glslpp.spirvToWGSL(alloc, spv, .{});
    defer alloc.free(wgsl);

    // The bare reserved keyword must not appear as a struct field name.
    // Field emission in spirv_to_wgsl is `    {name}: {type},` so the
    // distinctive substring to forbid is the keyword followed by `:`.
    if (std.mem.indexOf(u8, wgsl, "ref:")) |_| {
        std.debug.print(
            "WGSL output contains bare reserved keyword 'ref' as a field name:\n{s}\n",
            .{wgsl},
        );
        return error.WgslReservedKeywordEmitted;
    }
}
