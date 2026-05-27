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
    // Field emission is `    {name}: {type},` — anchor on the leading
    // indentation so we don't false-match `var ref: ...` or other accidental
    // substrings, and we don't accept `ref_:` as a member-form hit.
    if (std.mem.indexOf(u8, wgsl, "    ref:")) |_| {
        std.debug.print(
            "WGSL output contains bare reserved keyword 'ref' as a struct field:\n{s}\n",
            .{wgsl},
        );
        return error.WgslReservedKeywordEmitted;
    }
}

// M8.5 regression: WGSL backend must forward-declare the buffer_reference
// pointee struct. Before, `emitOneStructForwardDecl` only recursed through
// TypeArray member types, missing TypePointer — so the field
// `ref_: FloatRef,` was emitted without a corresponding `struct FloatRef`,
// and naga rejected the WGSL with `no definition in scope for identifier:
// FloatRef`.
test "buffer_reference WGSL backend emits pointee struct declaration" {
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

    if (std.mem.indexOf(u8, wgsl, "struct FloatRef") == null) {
        std.debug.print(
            "WGSL output references FloatRef but never declares it:\n{s}\n",
            .{wgsl},
        );
        return error.WgslMissingPointeeStruct;
    }
}

// Exercises the OpName-rename post-process for a non-member identifier:
// the uniform-block *instance* is named `ref` (a WGSL reserved word but a
// valid GLSL identifier). The previous code only sanitized struct member
// names via getMemberName; without the post-process, the emitted WGSL
// would declare `var<uniform> ref: U;` and naga would reject it the same
// way it did for member `ref:` fields.
test "WGSL post-process renames OpName-sourced variable named like a keyword" {
    const alloc = std.testing.allocator;
    const src =
        \\#version 450
        \\layout(set=0, binding=0) uniform U { vec4 color; } ref;
        \\layout(location=0) out vec4 fragColor;
        \\void main() { fragColor = ref.color; }
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);

    const wgsl = try glslpp.spirvToWGSL(alloc, spv, .{});
    defer alloc.free(wgsl);

    if (std.mem.indexOf(u8, wgsl, "var<uniform> ref:") != null) {
        std.debug.print(
            "WGSL output declares uniform variable using bare reserved name 'ref':\n{s}\n",
            .{wgsl},
        );
        return error.WgslReservedVariableEmitted;
    }
    if (std.mem.indexOf(u8, wgsl, "ref_") == null) {
        std.debug.print(
            "WGSL output is missing the sanitized variable name 'ref_':\n{s}\n",
            .{wgsl},
        );
        return error.WgslVariableNotSanitized;
    }
}
