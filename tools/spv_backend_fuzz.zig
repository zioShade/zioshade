const std = @import("std");
const glslpp = @import("glslpp");

/// Fuzz-test all SPIR-V backends with random valid SPIR-V modules.
/// The backends should never crash — at worst return an error.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const iterations: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 1000;

    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    var hlsl_ok: u32 = 0;
    var glsl_ok: u32 = 0;
    var msl_ok: u32 = 0;
    var wgsl_ok: u32 = 0;
    var hlsl_err: u32 = 0;
    var glsl_err: u32 = 0;
    var msl_err: u32 = 0;
    var wgsl_err: u32 = 0;

    for (0..iterations) |i| {
        var words = std.ArrayList(u32).initCapacity(alloc, 256) catch continue;
        defer words.deinit(alloc);

        var next_id: u32 = 1;

        const allocId = struct {
            fn call(nid: *u32) u32 {
                const id = nid.*;
                nid.* += 1;
                return id;
            }
        }.call;

        const is_frag = rng.boolean();

        // Header
        words.appendSlice(alloc, &[_]u32{ 0x07230203, 0x00010000, 0, 0, 0 }) catch continue;
        const bound_idx: usize = 3;

        // OpCapability Shader
        words.appendSlice(alloc, &.{ (2 << 16) | 17, 17 }) catch continue;

        // OpMemoryModel Logical GLSL450
        words.appendSlice(alloc, &.{ (3 << 16) | 14, 0, 1 }) catch continue;

        // Types
        const void_id = allocId(&next_id);
        const bool_id = allocId(&next_id);
        const float_id = allocId(&next_id);
        const int_id = allocId(&next_id);
        const vec4_id = allocId(&next_id);
        const func_type_id = allocId(&next_id);

        words.appendSlice(alloc, &.{ (2 << 16) | 19, void_id }) catch continue; // OpTypeVoid
        words.appendSlice(alloc, &.{ (2 << 16) | 21, bool_id }) catch continue; // OpTypeBool
        words.appendSlice(alloc, &.{ (3 << 16) | 22, float_id, 32 }) catch continue; // OpTypeFloat
        words.appendSlice(alloc, &.{ (4 << 16) | 21, int_id, 32, 1 }) catch continue; // OpTypeInt
        words.appendSlice(alloc, &.{ (3 << 16) | 23, vec4_id, float_id, 4 }) catch continue; // OpTypeVector
        words.appendSlice(alloc, &.{ (3 << 16) | 33, func_type_id, void_id }) catch continue; // OpTypeFunction

        // Constants
        const zero_f = allocId(&next_id);
        const one_f = allocId(&next_id);
        const two_f = allocId(&next_id);
        const zero_i = allocId(&next_id);
        words.appendSlice(alloc, &.{ (3 << 16) | 43, float_id, zero_f, 0 }) catch continue;
        words.appendSlice(alloc, &.{ (3 << 16) | 43, float_id, one_f, 0x3F800000 }) catch continue;
        words.appendSlice(alloc, &.{ (3 << 16) | 43, float_id, two_f, 0x40000000 }) catch continue;
        words.appendSlice(alloc, &.{ (3 << 16) | 41, int_id, zero_i, 0 }) catch continue;

        // Entry point
        const entry_id = allocId(&next_id);
        words.appendSlice(alloc, &.{ (4 << 16) | 15, if (is_frag) @as(u32, 4) else @as(u32, 0), entry_id, 0x6E69616D }) catch continue;
        words.append(alloc, 0) catch continue; // null term for "main"

        if (is_frag) {
            words.appendSlice(alloc, &.{ (3 << 16) | 16, entry_id, 1 }) catch continue;
        }

        // Function
        words.appendSlice(alloc, &.{ (5 << 16) | 54, void_id, entry_id, 0, func_type_id }) catch continue;

        // Label
        const lbl = allocId(&next_id);
        words.appendSlice(alloc, &.{ (2 << 16) | 248, lbl }) catch continue;

        // Random body
        var lf: u32 = zero_f;
        for (0..rng.intRangeAtMost(u32, 2, 20)) |_| {
            switch (rng.intRangeAtMost(u32, 0, 10)) {
                0 => {
                    const r = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (5 << 16) | 129, float_id, r, lf, one_f }) catch continue;
                    lf = r;
                },
                1 => {
                    const r = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (5 << 16) | 133, float_id, r, lf, one_f }) catch continue;
                    lf = r;
                },
                2 => {
                    const r = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (4 << 16) | 127, float_id, r, lf }) catch continue;
                    lf = r;
                },
                3 => {
                    const r = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (5 << 16) | 131, float_id, r, lf, one_f }) catch continue;
                    lf = r;
                },
                4 => {
                    const r = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (4 << 16) | 53, float_id, r, lf }) catch continue;
                    lf = r;
                },
                5 => {
                    const r = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (5 << 16) | 135, float_id, r, lf, two_f }) catch continue;
                    lf = r;
                },
                6 => {
                    // vec4 construct + extract
                    const vr = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (6 << 16) | 80, vec4_id, vr, lf, lf, lf, lf }) catch continue;
                    const er = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (5 << 16) | 81, float_id, er, vr, rng.intRangeAtMost(u32, 0, 3) }) catch continue;
                    lf = er;
                },
                7 => {
                    // FMod
                    const r = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (5 << 16) | 141, float_id, r, lf, two_f }) catch continue;
                    lf = r;
                },
                8 => {
                    // ConvertSToF
                    const r = allocId(&next_id);
                    words.appendSlice(alloc, &.{ (4 << 16) | 110, float_id, r, zero_i }) catch continue;
                    lf = r;
                },
                9, 10 => {}, // no-op for variety
                else => {},
            }
        }

        // OpReturn + OpFunctionEnd
        words.append(alloc, (1 << 16) | 253) catch continue;
        words.append(alloc, (1 << 16) | 56) catch continue;

        // Patch bound
        words.items[bound_idx] = next_id;

        // Test each backend
        if (glslpp.spirvToHLSL(alloc, words.items, .{})) |result| {
            alloc.free(result);
            hlsl_ok += 1;
        } else |_| {
            hlsl_err += 1;
        }

        if (glslpp.spirvToGLSL(alloc, words.items, .{})) |result| {
            alloc.free(result);
            glsl_ok += 1;
        } else |_| {
            glsl_err += 1;
        }

        if (glslpp.spirvToMSL(alloc, words.items, .{})) |result| {
            alloc.free(result);
            msl_ok += 1;
        } else |_| {
            msl_err += 1;
        }

        if (glslpp.spirvToWGSL(alloc, words.items, .{})) |result| {
            alloc.free(result);
            wgsl_ok += 1;
        } else |_| {
            wgsl_err += 1;
        }

        if ((i + 1) % 200 == 0) {
            std.debug.print("  {d}/{d} — HLSL:{d}/{d} GLSL:{d}/{d} MSL:{d}/{d} WGSL:{d}/{d}\n", .{
                i + 1,
                iterations,
                hlsl_ok,
                hlsl_err,
                glsl_ok,
                glsl_err,
                msl_ok,
                msl_err,
                wgsl_ok,
                wgsl_err,
            });
        }
    }

    std.debug.print("\n=== Backend Fuzz Results ({d} iterations) ===\n", .{iterations});
    std.debug.print("HLSL: {d} OK, {d} err\n", .{ hlsl_ok, hlsl_err });
    std.debug.print("GLSL: {d} OK, {d} err\n", .{ glsl_ok, glsl_err });
    std.debug.print("MSL:  {d} OK, {d} err\n", .{ msl_ok, msl_err });
    std.debug.print("WGSL: {d} OK, {d} err\n", .{ wgsl_ok, wgsl_err });
}
