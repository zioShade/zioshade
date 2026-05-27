// SPDX-License-Identifier: MIT OR Apache-2.0
//
// glslpp C ABI — Zig export wrappers that satisfy `include/glslpp.h`.
//
// Each `export fn` here matches a declaration in the public C header
// bit-for-bit (calling convention, parameter types, ordering, return type).
// External (non-Zig) consumers link against the static or shared library
// produced by the `c-lib` build step and call these symbols directly.
//
// Memory ownership
// ----------------
// Heap buffers handed back to the caller via out-parameters (SPIR-V word
// buffers from `glslpp_compile`, source strings from `glslpp_to_*`) use a
// length-prefix layout: the underlying allocator block is `[u64 length in
// bytes][payload...]`, but the caller sees a pointer to the payload. The
// matching `glslpp_free_*` helper reads the length back from the 8 bytes
// preceding the visible pointer and releases the whole block. Calling C
// `free()` on these pointers is undefined behaviour.
//
// Thread safety
// -------------
// The allocator and the last-error state are both `threadlocal`. Concurrent
// calls from different threads each see their own GeneralPurposeAllocator
// instance and their own error buffer. The error getters
// (`glslpp_last_error_*`) read state owned by the calling thread.

const std = @import("std");
const glslpp = @import("glslpp");

// ---------------------------------------------------------------------------
// Status codes — mirror `glslpp_status_t` in include/glslpp.h.
// ---------------------------------------------------------------------------

const GLSLPP_OK: c_int = 0;
const GLSLPP_ERR_OOM: c_int = 1;
const GLSLPP_ERR_LEX: c_int = 2;
const GLSLPP_ERR_PREPROCESS: c_int = 3;
const GLSLPP_ERR_PARSE: c_int = 4;
const GLSLPP_ERR_SEMANTIC: c_int = 5;
const GLSLPP_ERR_CODEGEN: c_int = 6;
const GLSLPP_ERR_INVALID_INPUT: c_int = 7;

// ---------------------------------------------------------------------------
// Threadlocal allocator
// ---------------------------------------------------------------------------
//
// Each thread that touches the C ABI gets its own GeneralPurposeAllocator.
// We never reset or deinit it — C callers manage the lifetime of returned
// buffers via the `glslpp_free_*` helpers, and the GPA itself lives until
// process exit. This matches what consumers of a typical C library expect.

threadlocal var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

fn alloc() std.mem.Allocator {
    return gpa.allocator();
}

// ---------------------------------------------------------------------------
// Length-prefix allocation
// ---------------------------------------------------------------------------
//
// Layout returned to the caller:
//   [u64 length in bytes (little-endian)][payload bytes...]
//                                       ^
//                                       caller sees this pointer
//
// `freeBytes` reads the u64 length back from the 8 bytes preceding the
// visible pointer and frees the whole block. NULL is a no-op.

const PREFIX: usize = 8;

fn allocBytes(n: usize) ?[*]u8 {
    const a = alloc();
    const buf = a.alloc(u8, PREFIX + n) catch return null;
    std.mem.writeInt(u64, buf[0..8], @as(u64, n), .little);
    return buf.ptr + PREFIX;
}

fn freeBytes(p: ?[*]u8) void {
    const raw = p orelse return;
    const start = raw - PREFIX;
    const n: usize = @intCast(std.mem.readInt(u64, start[0..8], .little));
    alloc().free(start[0 .. PREFIX + n]);
}

// ---------------------------------------------------------------------------
// Threadlocal error state
// ---------------------------------------------------------------------------
//
// The header says `glslpp_last_error_message`'s returned pointer is
// "overwritten by the next failing glslpp_* call on the same thread", so a
// fixed-size threadlocal buffer is the right shape. We hold a NUL-terminated
// formatted string plus the 1-based line/column when available.

threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;
threadlocal var last_error_line_tl: u32 = 0;
threadlocal var last_error_column_tl: u32 = 0;

fn clearLastError() void {
    last_error_len = 0;
    last_error_line_tl = 0;
    last_error_column_tl = 0;
}

fn setLastError(err: anyerror) c_int {
    const status = statusFromErr(err);

    // Capture source location captured by the compiler pipeline.
    last_error_line_tl = glslpp.semantic.last_error_line;
    last_error_column_tl = glslpp.semantic.last_error_column;

    // Format "<error tag>: <inner-or-ctx>". Falls back gracefully if either
    // piece is missing.
    const inner = glslpp.lastErrorInner() orelse "";
    const ctx = glslpp.lastErrorCtx() orelse "";
    const detail: []const u8 = if (inner.len > 0) inner else ctx;

    const written = std.fmt.bufPrint(last_error_buf[0 .. last_error_buf.len - 1], "{s}: {s}", .{
        @errorName(err),
        detail,
    }) catch blk: {
        // bufPrint can only fail if the buffer is too small; truncate to the
        // error name in that case.
        const fallback = std.fmt.bufPrint(last_error_buf[0 .. last_error_buf.len - 1], "{s}", .{@errorName(err)}) catch last_error_buf[0..0];
        break :blk fallback;
    };
    last_error_len = written.len;
    last_error_buf[last_error_len] = 0;

    return status;
}

fn setInvalidInputError(message: []const u8) c_int {
    last_error_line_tl = 0;
    last_error_column_tl = 0;

    const written = std.fmt.bufPrint(last_error_buf[0 .. last_error_buf.len - 1], "InvalidInput: {s}", .{message}) catch last_error_buf[0..0];
    last_error_len = written.len;
    last_error_buf[last_error_len] = 0;

    return GLSLPP_ERR_INVALID_INPUT;
}

fn statusFromErr(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => GLSLPP_ERR_OOM,
        error.LexFailed => GLSLPP_ERR_LEX,
        error.PreprocessFailed => GLSLPP_ERR_PREPROCESS,
        error.ParseFailed => GLSLPP_ERR_PARSE,
        error.SemanticFailed => GLSLPP_ERR_SEMANTIC,
        error.CodegenFailed, error.EntryPointNotFound => GLSLPP_ERR_CODEGEN,
        // Backend cross-compile errors (CrossCompileUnsupported, etc.) and
        // anything else we haven't categorised gets bucketed as codegen.
        else => GLSLPP_ERR_CODEGEN,
    };
}

// ---------------------------------------------------------------------------
// Enum mapping
// ---------------------------------------------------------------------------

fn stageFromC(c_stage: c_int) ?glslpp.Stage {
    return switch (c_stage) {
        0 => .vertex,
        1 => .fragment,
        2 => .compute,
        3 => .geometry,
        4 => .tessellation_control,
        5 => .tessellation_evaluation,
        6 => .mesh,
        7 => .task,
        8 => .raygen,
        9 => .closesthit,
        10 => .miss,
        11 => .intersection,
        12 => .anyhit,
        13 => .callable,
        else => null,
    };
}

fn spirvVersionFromPacked(packed_ver: u32) ?glslpp.SPIRVVersion {
    return switch (packed_ver) {
        10 => .@"1.0",
        11 => .@"1.1",
        12 => .@"1.2",
        13 => .@"1.3",
        14 => .@"1.4",
        15 => .@"1.5",
        16 => .@"1.6",
        else => null,
    };
}

// ---------------------------------------------------------------------------
// C struct mirrors
// ---------------------------------------------------------------------------
//
// `glslpp_compile_options_t` is laid out to match the C header. Because the
// C enum on every supported target is at least int-sized, we use `c_int` for
// the stage field — that matches what a C compiler emits for an enum.

const glslpp_compile_options_t = extern struct {
    stage: c_int,
    version: u32,
    is_essl: c_int,
    spirv_version_packed: u32,
};

// ---------------------------------------------------------------------------
// GLSL -> SPIR-V
// ---------------------------------------------------------------------------

/// Compile GLSL source to a SPIR-V module. On success, `*spirv_words`
/// receives a length-prefixed buffer owned by the caller (release via
/// `glslpp_free_u32`).
pub export fn glslpp_compile(
    glsl_source: ?[*]const u8,
    glsl_len: usize,
    opts: ?*const glslpp_compile_options_t,
    spirv_words: ?*?[*]u32,
    spirv_word_count: ?*usize,
) callconv(.c) c_int {
    // Output parameters are required.
    const out_words = spirv_words orelse return setInvalidInputError("spirv_words out-pointer is NULL");
    const out_count = spirv_word_count orelse return setInvalidInputError("spirv_word_count out-pointer is NULL");

    // Reset outputs upfront so callers don't read stale values on failure.
    out_words.* = null;
    out_count.* = 0;

    // glsl_source may be NULL only if glsl_len == 0.
    if (glsl_source == null and glsl_len > 0) {
        return setInvalidInputError("glsl_source is NULL but glsl_len > 0");
    }

    clearLastError();

    // Resolve options (NULL means defaults). The `is_essl` C field is
    // accepted at the boundary but currently informational only — the
    // preprocessor detects ESSL from the `#version` line.
    var stage: glslpp.Stage = .fragment;
    var version: u32 = 430;
    var spirv_ver: glslpp.SPIRVVersion = .@"1.5";
    if (opts) |o| {
        stage = stageFromC(o.stage) orelse return setInvalidInputError("stage value out of range");
        version = o.version;
        spirv_ver = spirvVersionFromPacked(o.spirv_version_packed) orelse return setInvalidInputError("spirv_version_packed value out of range");
    }

    // Copy the source into a null-terminated heap slice. The Zig API
    // requires `[:0]const u8`.
    const a = alloc();
    const src_buf = a.alloc(u8, glsl_len + 1) catch return setLastError(error.OutOfMemory);
    defer a.free(src_buf);
    if (glsl_len > 0) {
        @memcpy(src_buf[0..glsl_len], glsl_source.?[0..glsl_len]);
    }
    src_buf[glsl_len] = 0;
    const src_z: [:0]const u8 = src_buf[0..glsl_len :0];

    const compile_opts: glslpp.CompileOptions = .{
        .stage = stage,
        .version = version,
        .spirv_version = spirv_ver,
    };

    const words = glslpp.compileToSPIRV(a, src_z, compile_opts) catch |err| {
        return setLastError(err);
    };
    defer a.free(words);

    // Copy into a length-prefixed buffer the caller will free via
    // `glslpp_free_u32`.
    const byte_len = words.len * @sizeOf(u32);
    const payload = allocBytes(byte_len) orelse return setLastError(error.OutOfMemory);
    @memcpy(payload[0..byte_len], std.mem.sliceAsBytes(words));

    out_words.* = @as([*]u32, @ptrCast(@alignCast(payload)));
    out_count.* = words.len;

    return GLSLPP_OK;
}

// ---------------------------------------------------------------------------
// SPIR-V -> backend languages
// ---------------------------------------------------------------------------

/// Validate inputs common to every cross-compile entry point. Returns null on
/// success; on failure, writes the error state and returns the status code.
fn validateSpirvInputs(spirv_words: ?[*]const u32, spirv_word_count: usize) ?c_int {
    if (spirv_words == null) return setInvalidInputError("spirv_words is NULL");
    if (spirv_word_count < 5) return setInvalidInputError("spirv_word_count too small (need >= 5 for header)");
    return null;
}

fn finishString(out_buf: *?[*]u8, out_len: *usize, source: []const u8) c_int {
    // We allocate `source.len + 1` to fit a trailing NUL the C side may
    // rely on for convenience. `*out_len` reports the byte count WITHOUT
    // the terminator, matching the header contract.
    const payload = allocBytes(source.len + 1) orelse return setLastError(error.OutOfMemory);
    @memcpy(payload[0..source.len], source);
    payload[source.len] = 0;
    out_buf.* = payload;
    out_len.* = source.len;
    return GLSLPP_OK;
}

fn resolveEntryPoint(entry_point: ?[*:0]const u8) []const u8 {
    if (entry_point) |ep| return std.mem.span(ep);
    return "main";
}

/// Cross-compile SPIR-V to HLSL source.
pub export fn glslpp_to_hlsl(
    spirv_words: ?[*]const u32,
    spirv_word_count: usize,
    binding_shift: i32,
    shader_model: u32,
    entry_point: ?[*:0]const u8,
    hlsl: ?*?[*]u8,
    hlsl_len: ?*usize,
) callconv(.c) c_int {
    const out_buf = hlsl orelse return setInvalidInputError("hlsl out-pointer is NULL");
    const out_len = hlsl_len orelse return setInvalidInputError("hlsl_len out-pointer is NULL");
    out_buf.* = null;
    out_len.* = 0;

    if (validateSpirvInputs(spirv_words, spirv_word_count)) |status| return status;
    clearLastError();

    const words = spirv_words.?[0..spirv_word_count];
    const ep_name = resolveEntryPoint(entry_point);

    const result = glslpp.spirvToHLSL(alloc(), words, .{
        .binding_shift = binding_shift,
        .shader_model = shader_model,
        .entry_point_name = ep_name,
    }) catch |err| return setLastError(err);
    defer alloc().free(result);

    return finishString(out_buf, out_len, result);
}

/// Cross-compile SPIR-V to GLSL source.
pub export fn glslpp_to_glsl(
    spirv_words: ?[*]const u32,
    spirv_word_count: usize,
    glsl_version: u32,
    es: c_int,
    entry_point: ?[*:0]const u8,
    glsl: ?*?[*]u8,
    glsl_len: ?*usize,
) callconv(.c) c_int {
    const out_buf = glsl orelse return setInvalidInputError("glsl out-pointer is NULL");
    const out_len = glsl_len orelse return setInvalidInputError("glsl_len out-pointer is NULL");
    out_buf.* = null;
    out_len.* = 0;

    if (validateSpirvInputs(spirv_words, spirv_word_count)) |status| return status;
    clearLastError();

    const words = spirv_words.?[0..spirv_word_count];
    const ep_name = resolveEntryPoint(entry_point);

    const result = glslpp.spirvToGLSL(alloc(), words, .{
        .version = glsl_version,
        .es = es != 0,
        .entry_point_name = ep_name,
    }) catch |err| return setLastError(err);
    defer alloc().free(result);

    return finishString(out_buf, out_len, result);
}

/// Cross-compile SPIR-V to Metal Shading Language source.
///
/// `argument_buffers` is accepted for forward-compat with M6 but the
/// underlying Zig MSL backend does not yet expose an argument-buffers
/// option, so the parameter is currently ignored.
pub export fn glslpp_to_msl(
    spirv_words: ?[*]const u32,
    spirv_word_count: usize,
    metal_version: u32,
    argument_buffers: c_int,
    entry_point: ?[*:0]const u8,
    msl: ?*?[*]u8,
    msl_len: ?*usize,
) callconv(.c) c_int {
    _ = argument_buffers; // Reserved — see doc comment above.

    const out_buf = msl orelse return setInvalidInputError("msl out-pointer is NULL");
    const out_len = msl_len orelse return setInvalidInputError("msl_len out-pointer is NULL");
    out_buf.* = null;
    out_len.* = 0;

    if (validateSpirvInputs(spirv_words, spirv_word_count)) |status| return status;
    clearLastError();

    const words = spirv_words.?[0..spirv_word_count];
    const ep_name = resolveEntryPoint(entry_point);

    const result = glslpp.spirvToMSL(alloc(), words, .{
        .metal_version = metal_version,
        .entry_point_name = ep_name,
    }) catch |err| return setLastError(err);
    defer alloc().free(result);

    return finishString(out_buf, out_len, result);
}

/// Cross-compile SPIR-V to WGSL source.
pub export fn glslpp_to_wgsl(
    spirv_words: ?[*]const u32,
    spirv_word_count: usize,
    entry_point: ?[*:0]const u8,
    wgsl: ?*?[*]u8,
    wgsl_len: ?*usize,
) callconv(.c) c_int {
    const out_buf = wgsl orelse return setInvalidInputError("wgsl out-pointer is NULL");
    const out_len = wgsl_len orelse return setInvalidInputError("wgsl_len out-pointer is NULL");
    out_buf.* = null;
    out_len.* = 0;

    if (validateSpirvInputs(spirv_words, spirv_word_count)) |status| return status;
    clearLastError();

    const words = spirv_words.?[0..spirv_word_count];
    const ep_name = resolveEntryPoint(entry_point);

    const result = glslpp.spirvToWGSL(alloc(), words, .{
        .entry_point_name = ep_name,
    }) catch |err| return setLastError(err);
    defer alloc().free(result);

    return finishString(out_buf, out_len, result);
}

// ---------------------------------------------------------------------------
// Error reporting
// ---------------------------------------------------------------------------

/// Returns the threadlocal error message, or NULL if no error has been
/// recorded since the last successful call.
pub export fn glslpp_last_error_message() callconv(.c) ?[*:0]const u8 {
    if (last_error_len == 0) return null;
    return @as([*:0]const u8, @ptrCast(&last_error_buf[0]));
}

/// Returns the 1-based source line of the most recent error, or 0 if not
/// available.
pub export fn glslpp_last_error_line() callconv(.c) u32 {
    return last_error_line_tl;
}

/// Returns the 1-based source column of the most recent error, or 0 if not
/// available.
pub export fn glslpp_last_error_column() callconv(.c) u32 {
    return last_error_column_tl;
}

// ---------------------------------------------------------------------------
// Buffer release
// ---------------------------------------------------------------------------

/// Free a string buffer previously returned by `glslpp_to_*`. NULL-safe.
pub export fn glslpp_free_str(s: ?[*]u8) callconv(.c) void {
    freeBytes(s);
}

/// Free a SPIR-V word buffer previously returned by `glslpp_compile`.
/// NULL-safe.
pub export fn glslpp_free_u32(p: ?[*]u32) callconv(.c) void {
    if (p) |ptr| {
        freeBytes(@as([*]u8, @ptrCast(@alignCast(ptr))));
    }
}

test {
    // Ensure the export functions get type-checked when running unit tests
    // that touch this module.
    _ = &glslpp_compile;
    _ = &glslpp_to_hlsl;
    _ = &glslpp_to_glsl;
    _ = &glslpp_to_msl;
    _ = &glslpp_to_wgsl;
    _ = &glslpp_last_error_message;
    _ = &glslpp_last_error_line;
    _ = &glslpp_last_error_column;
    _ = &glslpp_free_str;
    _ = &glslpp_free_u32;
}
