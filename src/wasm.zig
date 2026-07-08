// SPDX-License-Identifier: MIT OR Apache-2.0
//
// zioshade WASM entry module — a thin C-ABI surface for the browser
// playground. It wraps the public one-shot cross-compile functions
// (`compileGlslToHlsl` and friends) so JavaScript can hand a GLSL string
// across the wasm boundary and read a backend source string back out.
//
// This module is compiled by the `wasm` build step into a
// wasm32-freestanding module with no libc and no entry point. Only the
// `export fn`s below are visible to the host.
//
// Boundary protocol (see web/playground.js for the JS counterpart)
// ----------------------------------------------------------------
// JavaScript cannot pass a Zig slice, so strings cross as (pointer, length)
// pairs into linear memory:
//
//   1. JS calls `zs_alloc(len)` to reserve `len` bytes and gets an offset.
//   2. JS writes the UTF-8 GLSL source into memory at that offset.
//   3. JS calls `zs_compile(backend, src_ptr, src_len)`. On success the
//      result string is stashed in threadlocal state; the call returns 0.
//      On failure it returns a negative status and stashes an error string
//      instead.
//   4. JS calls `zs_result_ptr()` / `zs_result_len()` to locate the result
//      (or error) bytes, then decodes them with TextDecoder.
//   5. JS calls `zs_free(ptr, len)` to release the input buffer it allocated
//      in step 1. The result buffer is owned by this module and is freed on
//      the next `zs_compile` call, so JS must decode it before compiling
//      again.
//
// Single-threaded model
// ---------------------
// A wasm module instance runs on one thread, so the `threadlocal`
// result/error state below is effectively global-but-safe. There is no
// concurrent access to worry about.

const std = @import("std");
const zioshade = @import("zioshade");

// Override std's default logger. The library calls `std.log.warn`/`err` on a
// handful of internal diagnostics; the default implementation writes to stderr
// via std.posix, which does not exist on wasm32-freestanding. There is no
// console to write to from a bare wasm module anyway, so we drop log records on
// the floor. Real compile errors still reach the caller through `zs_compile`'s
// return status and the stashed error string.
pub const std_options: std.Options = .{
    .logFn = noopLog,
};

fn noopLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

// The wasm_allocator is a bump-style allocator backed by the wasm linear
// memory (`memory.grow`). It is the canonical allocator for
// wasm32-freestanding: no libc, no OS syscalls.
const gpa = std.heap.wasm_allocator;

// Backend selector shared with the JS side. Keep these integer values in
// sync with the `BACKENDS` table in web/playground.js.
const Backend = enum(u32) {
    hlsl = 0,
    msl = 1,
    glsl = 2,
    wgsl = 3,
};

// Status codes returned by `zs_compile`. 0 means success; negatives are
// failures. JS treats any non-zero return as "read the result buffer as an
// error message".
const ZS_OK: i32 = 0;
const ZS_ERR_BAD_BACKEND: i32 = -1;
const ZS_ERR_BAD_INPUT: i32 = -2;
const ZS_ERR_COMPILE: i32 = -3;
const ZS_ERR_OOM: i32 = -4;

// Threadlocal (effectively single-instance) result state. After a
// `zs_compile` call, this points at either the compiled backend source or a
// formatted error message. It is owned by this module: the previous buffer
// is freed at the start of every `zs_compile`.
threadlocal var result: []u8 = &.{};

// Scratch buffer for formatting error messages before they are copied into
// the result slot.
threadlocal var error_buf: [1024]u8 = undefined;

// ---------------------------------------------------------------------------
// Memory management exports — JS uses these to pass the source string in.
// ---------------------------------------------------------------------------

/// Reserve `len` bytes in wasm linear memory and return the offset. JS writes
/// the UTF-8 source there before calling `zs_compile`. Returns 0 on OOM (JS
/// treats a 0 offset as allocation failure; a real allocation never lands at
/// offset 0 because the module's static data occupies the low addresses).
export fn zs_alloc(len: usize) usize {
    if (len == 0) return 0;
    const buf = gpa.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

/// Release a buffer previously handed out by `zs_alloc`. JS must pass back the
/// same `ptr` and `len` it received/requested.
export fn zs_free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;
    const many: [*]u8 = @ptrFromInt(ptr);
    gpa.free(many[0..len]);
}

// ---------------------------------------------------------------------------
// Compile export
// ---------------------------------------------------------------------------

/// Compile a UTF-8 GLSL fragment-shader source to the chosen backend.
///
/// `backend` is a `Backend` tag value; `src_ptr`/`src_len` locate the source
/// bytes in linear memory (as reserved via `zs_alloc`). On success returns
/// `ZS_OK` and stashes the backend source string; retrieve it with
/// `zs_result_ptr`/`zs_result_len`. On failure returns a negative status and
/// stashes a human-readable error string in the same slot.
///
/// The playground compiles fragment shaders (the common case for the
/// Shadertoy-style shaders zioshade targets). A future revision can thread a
/// stage selector through the same ABI.
export fn zs_compile(backend: u32, src_ptr: usize, src_len: usize) i32 {
    // Release the previous result so repeated calls do not leak.
    freeResult();

    const be = std.meta.intToEnum(Backend, backend) catch {
        return storeError(ZS_ERR_BAD_BACKEND, "unknown backend selector {d}", .{backend});
    };

    if (src_ptr == 0 and src_len > 0) {
        return storeError(ZS_ERR_BAD_INPUT, "source pointer is null but length is {d}", .{src_len});
    }

    // The Zig API wants a null-terminated `[:0]const u8`. Copy the incoming
    // bytes into an owned NUL-terminated buffer.
    const src_z = gpa.allocSentinel(u8, src_len, 0) catch {
        return storeError(ZS_ERR_OOM, "out of memory copying {d}-byte source", .{src_len});
    };
    defer gpa.free(src_z);
    if (src_len > 0) {
        const many: [*]const u8 = @ptrFromInt(src_ptr);
        @memcpy(src_z[0..src_len], many[0..src_len]);
    }

    const out: [:0]const u8 = switch (be) {
        .hlsl => zioshade.compileGlslToHlsl(gpa, src_z, .fragment),
        .msl => zioshade.compileGlslToMsl(gpa, src_z, .fragment),
        .glsl => zioshade.compileGlslToGlsl(gpa, src_z, .fragment),
        .wgsl => zioshade.compileGlslToWgsl(gpa, src_z, .fragment),
    } catch |err| {
        // Surface any pipeline detail zioshade recorded alongside the tag.
        const inner = zioshade.lastErrorInner() orelse zioshade.lastErrorCtx() orelse "";
        if (inner.len > 0) {
            return storeError(ZS_ERR_COMPILE, "{s}: {s}", .{ @errorName(err), inner });
        }
        return storeError(ZS_ERR_COMPILE, "{s}", .{@errorName(err)});
    };
    defer gpa.free(out);

    // Copy the backend source into the result slot (owned by this module).
    result = gpa.dupe(u8, out) catch {
        return storeError(ZS_ERR_OOM, "out of memory storing result", .{});
    };
    return ZS_OK;
}

// ---------------------------------------------------------------------------
// Result accessors — JS reads the result/error bytes through these.
// ---------------------------------------------------------------------------

/// Offset of the current result (or error) bytes in linear memory.
export fn zs_result_ptr() usize {
    return @intFromPtr(result.ptr);
}

/// Length in bytes of the current result (or error) string.
export fn zs_result_len() usize {
    return result.len;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn freeResult() void {
    if (result.len > 0) {
        gpa.free(result);
        result = &.{};
    }
}

/// Format an error message into the result slot and return `status`. If the
/// message does not fit the scratch buffer it is truncated; if even the copy
/// into the result slot fails we fall back to an empty result so the caller
/// still gets a clean status code.
fn storeError(status: i32, comptime fmt: []const u8, args: anytype) i32 {
    const msg = std.fmt.bufPrint(&error_buf, fmt, args) catch error_buf[0..error_buf.len];
    result = gpa.dupe(u8, msg) catch &.{};
    return status;
}
