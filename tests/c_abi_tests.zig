// SPDX-License-Identifier: MIT OR Apache-2.0
//
// C ABI sanity tests — exercise the `export fn` wrappers in `src/c_abi.zig`
// directly from Zig. These tests pin the calling convention, the
// length-prefix free protocol, the last-error reporting, and NULL-input
// behaviour. They are run as part of `zig build test` (via the
// `test-c-abi` step).

const std = @import("std");
const c_abi = @import("c_abi");

// `glslpp_compile_options_t` is an `extern struct` that we have to redeclare
// here because it is private to `src/c_abi.zig`. The shape is fixed by the
// C header and must match bit-for-bit.
const CompileOptions = extern struct {
    stage: c_int,
    version: u32,
    is_essl: c_int,
    spirv_version_packed: u32,
};

const STATUS_OK: c_int = 0;
const STATUS_INVALID_INPUT: c_int = 7;

const MINIMAL_FRAG: []const u8 =
    "#version 430\nlayout(location = 0) out vec4 FragColor;\nvoid main() { FragColor = vec4(1.0); }";

// A shader whose stage requires SPIR-V 1.4+ — compiled against 1.3 it
// reliably fails at codegen. This mirrors the negative-path test in
// `tests/mesh_task_tests.zig`.
const BROKEN_MESH: []const u8 =
    "#version 450\n#extension GL_EXT_mesh_shader : require\nlayout(local_size_x = 32) in;\nvoid main() {}";

/// Convert the last-error message to a Zig slice for comparisons.
fn lastErrorSlice() ?[]const u8 {
    const ptr = c_abi.glslpp_last_error_message() orelse return null;
    return std.mem.span(ptr);
}

test "glslpp_compile happy path -> SPIR-V -> HLSL" {
    var words: ?[*]u32 = null;
    var word_count: usize = 0;

    const opts: CompileOptions = .{
        .stage = 1, // FRAGMENT
        .version = 430,
        .is_essl = 0,
        .spirv_version_packed = 15,
    };

    const status = c_abi.glslpp_compile(
        MINIMAL_FRAG.ptr,
        MINIMAL_FRAG.len,
        @ptrCast(&opts),
        &words,
        &word_count,
    );
    try std.testing.expectEqual(STATUS_OK, status);
    try std.testing.expect(words != null);
    try std.testing.expect(word_count >= 5);
    // SPIR-V magic number in the first word.
    try std.testing.expectEqual(@as(u32, 0x07230203), words.?[0]);

    var hlsl: ?[*]u8 = null;
    var hlsl_len: usize = 0;
    const hstatus = c_abi.glslpp_to_hlsl(
        @ptrCast(words),
        word_count,
        0,
        60,
        "main",
        &hlsl,
        &hlsl_len,
    );
    try std.testing.expectEqual(STATUS_OK, hstatus);
    try std.testing.expect(hlsl != null);
    try std.testing.expect(hlsl_len > 0);
    // Convenience NUL terminator is present.
    try std.testing.expectEqual(@as(u8, 0), hlsl.?[hlsl_len]);

    c_abi.glslpp_free_str(hlsl);
    c_abi.glslpp_free_u32(words);
}

test "glslpp_compile with NULL opts uses defaults" {
    var words: ?[*]u32 = null;
    var word_count: usize = 0;

    const status = c_abi.glslpp_compile(
        MINIMAL_FRAG.ptr,
        MINIMAL_FRAG.len,
        null,
        &words,
        &word_count,
    );
    try std.testing.expectEqual(STATUS_OK, status);
    try std.testing.expect(words != null);
    try std.testing.expect(word_count >= 5);

    c_abi.glslpp_free_u32(words);
}

test "glslpp_to_hlsl with NULL entry_point treats it as \"main\"" {
    var words: ?[*]u32 = null;
    var word_count: usize = 0;
    const cstatus = c_abi.glslpp_compile(
        MINIMAL_FRAG.ptr,
        MINIMAL_FRAG.len,
        null,
        &words,
        &word_count,
    );
    try std.testing.expectEqual(STATUS_OK, cstatus);
    defer c_abi.glslpp_free_u32(words);

    var hlsl: ?[*]u8 = null;
    var hlsl_len: usize = 0;
    const hstatus = c_abi.glslpp_to_hlsl(
        @ptrCast(words),
        word_count,
        0,
        60,
        null, // entry_point = NULL -> "main"
        &hlsl,
        &hlsl_len,
    );
    try std.testing.expectEqual(STATUS_OK, hstatus);
    try std.testing.expect(hlsl != null);
    try std.testing.expect(hlsl_len > 0);
    c_abi.glslpp_free_str(hlsl);
}

test "glslpp_compile rejects out-of-range stage" {
    var words: ?[*]u32 = null;
    var word_count: usize = 0;
    const opts: CompileOptions = .{
        .stage = 99, // out of range
        .version = 430,
        .is_essl = 0,
        .spirv_version_packed = 15,
    };
    const status = c_abi.glslpp_compile(
        MINIMAL_FRAG.ptr,
        MINIMAL_FRAG.len,
        @ptrCast(&opts),
        &words,
        &word_count,
    );
    try std.testing.expectEqual(STATUS_INVALID_INPUT, status);
    try std.testing.expectEqual(@as(?[*]u32, null), words);
    try std.testing.expectEqual(@as(usize, 0), word_count);
}

test "glslpp_compile rejects bad SPIR-V version" {
    var words: ?[*]u32 = null;
    var word_count: usize = 0;
    const opts: CompileOptions = .{
        .stage = 1,
        .version = 430,
        .is_essl = 0,
        .spirv_version_packed = 99,
    };
    const status = c_abi.glslpp_compile(
        MINIMAL_FRAG.ptr,
        MINIMAL_FRAG.len,
        @ptrCast(&opts),
        &words,
        &word_count,
    );
    try std.testing.expectEqual(STATUS_INVALID_INPUT, status);
}

test "glslpp_compile rejects NULL source with non-zero length" {
    var words: ?[*]u32 = null;
    var word_count: usize = 0;
    const status = c_abi.glslpp_compile(null, 16, null, &words, &word_count);
    try std.testing.expectEqual(STATUS_INVALID_INPUT, status);
}

test "glslpp_compile accepts NULL source with zero length" {
    // Zero-length input should be accepted at the boundary. It will almost
    // certainly fail somewhere in the compilation pipeline (no entry point,
    // etc.) but that's a SEMANTIC/CODEGEN failure, not INVALID_INPUT.
    var words: ?[*]u32 = null;
    var word_count: usize = 0;
    const status = c_abi.glslpp_compile(null, 0, null, &words, &word_count);
    try std.testing.expect(status != STATUS_INVALID_INPUT);
}

test "failed compile populates last_error_message" {
    var words: ?[*]u32 = null;
    var word_count: usize = 0;
    // Mesh stage on SPIR-V 1.3 fails at codegen.
    const opts: CompileOptions = .{
        .stage = 6, // MESH
        .version = 450,
        .is_essl = 0,
        .spirv_version_packed = 13,
    };
    const status = c_abi.glslpp_compile(
        BROKEN_MESH.ptr,
        BROKEN_MESH.len,
        @ptrCast(&opts),
        &words,
        &word_count,
    );
    try std.testing.expect(status != STATUS_OK);
    try std.testing.expectEqual(@as(?[*]u32, null), words);

    const msg = lastErrorSlice() orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(msg.len > 0);
    // The message should mention the error kind ("CodegenFailed: ...").
    try std.testing.expect(std.mem.indexOf(u8, msg, "Failed") != null or
        std.mem.indexOf(u8, msg, "failed") != null);
}

test "second compile after failure succeeds (no sticky error state)" {
    var words: ?[*]u32 = null;
    var word_count: usize = 0;
    const bad_opts: CompileOptions = .{
        .stage = 6,
        .version = 450,
        .is_essl = 0,
        .spirv_version_packed = 13,
    };
    _ = c_abi.glslpp_compile(BROKEN_MESH.ptr, BROKEN_MESH.len, @ptrCast(&bad_opts), &words, &word_count);
    if (words) |w| c_abi.glslpp_free_u32(w);
    words = null;
    word_count = 0;

    const status = c_abi.glslpp_compile(
        MINIMAL_FRAG.ptr,
        MINIMAL_FRAG.len,
        null,
        &words,
        &word_count,
    );
    try std.testing.expectEqual(STATUS_OK, status);
    try std.testing.expect(word_count >= 5);
    // After a clean compile the error message should have been cleared.
    try std.testing.expectEqual(@as(?[*:0]const u8, null), c_abi.glslpp_last_error_message());
    try std.testing.expectEqual(@as(u32, 0), c_abi.glslpp_last_error_line());

    c_abi.glslpp_free_u32(words);
}

test "glslpp_free_str / glslpp_free_u32 NULL is a no-op" {
    c_abi.glslpp_free_str(null);
    c_abi.glslpp_free_u32(null);
    // If we got here without crashing the contract holds.
}

test "cross-compile to all four backends" {
    var words: ?[*]u32 = null;
    var word_count: usize = 0;
    const cstatus = c_abi.glslpp_compile(
        MINIMAL_FRAG.ptr,
        MINIMAL_FRAG.len,
        null,
        &words,
        &word_count,
    );
    try std.testing.expectEqual(STATUS_OK, cstatus);
    defer c_abi.glslpp_free_u32(words);

    // HLSL
    {
        var buf: ?[*]u8 = null;
        var n: usize = 0;
        const s = c_abi.glslpp_to_hlsl(@ptrCast(words), word_count, 0, 60, null, &buf, &n);
        try std.testing.expectEqual(STATUS_OK, s);
        try std.testing.expect(n > 0);
        c_abi.glslpp_free_str(buf);
    }
    // GLSL
    {
        var buf: ?[*]u8 = null;
        var n: usize = 0;
        const s = c_abi.glslpp_to_glsl(@ptrCast(words), word_count, 330, 0, null, &buf, &n);
        try std.testing.expectEqual(STATUS_OK, s);
        try std.testing.expect(n > 0);
        c_abi.glslpp_free_str(buf);
    }
    // MSL
    {
        var buf: ?[*]u8 = null;
        var n: usize = 0;
        const s = c_abi.glslpp_to_msl(@ptrCast(words), word_count, 21, 0, null, &buf, &n);
        try std.testing.expectEqual(STATUS_OK, s);
        try std.testing.expect(n > 0);
        c_abi.glslpp_free_str(buf);
    }
    // WGSL
    {
        var buf: ?[*]u8 = null;
        var n: usize = 0;
        const s = c_abi.glslpp_to_wgsl(@ptrCast(words), word_count, null, &buf, &n);
        try std.testing.expectEqual(STATUS_OK, s);
        try std.testing.expect(n > 0);
        c_abi.glslpp_free_str(buf);
    }
}

test "glslpp_to_hlsl rejects NULL spirv_words" {
    var hlsl: ?[*]u8 = null;
    var hlsl_len: usize = 0;
    const status = c_abi.glslpp_to_hlsl(null, 0, 0, 60, null, &hlsl, &hlsl_len);
    try std.testing.expectEqual(STATUS_INVALID_INPUT, status);
    try std.testing.expectEqual(@as(?[*]u8, null), hlsl);
}

test "glslpp_to_hlsl rejects too-small SPIR-V" {
    const stub = [_]u32{ 0, 0 };
    var hlsl: ?[*]u8 = null;
    var hlsl_len: usize = 0;
    const status = c_abi.glslpp_to_hlsl(&stub, stub.len, 0, 60, null, &hlsl, &hlsl_len);
    try std.testing.expectEqual(STATUS_INVALID_INPUT, status);
}
