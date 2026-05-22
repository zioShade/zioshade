const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Usage: cross_validate_all <spirv_bins_dir>\n", .{});
        return;
    }

    const dir_path = args[1];
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var total: u32 = 0;
    var hlsl_ok: u32 = 0;
    var glsl_ok: u32 = 0;
    var msl_ok: u32 = 0;
    var wgsl_ok: u32 = 0;
    var hlsl_fail: u32 = 0;
    var glsl_fail: u32 = 0;
    var msl_fail: u32 = 0;
    var wgsl_fail: u32 = 0;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".spv")) continue;

        total += 1;
        const name = entry.path;

        const file = try dir.openFile(name, .{});
        defer file.close();
        const data = try file.readToEndAlloc(alloc, 1024 * 1024);
        defer alloc.free(data);

        // Interpret as u32 words (copy to properly aligned buffer)
        if (data.len < 20 or data.len % 4 != 0) continue;
        const word_count = data.len / 4;
        const words = try alloc.alloc(u32, word_count);
        defer alloc.free(words);
        for (0..word_count) |i| {
            words[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
        }

        // HLSL
        if (glslpp.spirvToHLSL(alloc, words, .{})) |result| {
            alloc.free(result);
            hlsl_ok += 1;
        } else |_| {
            hlsl_fail += 1;
            if (hlsl_fail <= 5) std.debug.print("  HLSL FAIL: {s}\n", .{name});
        }

        // GLSL
        if (glslpp.spirvToGLSL(alloc, words, .{})) |result| {
            alloc.free(result);
            glsl_ok += 1;
        } else |_| {
            glsl_fail += 1;
            if (glsl_fail <= 5) std.debug.print("  GLSL FAIL: {s}\n", .{name});
        }

        // MSL
        if (glslpp.spirvToMSL(alloc, words, .{})) |result| {
            alloc.free(result);
            msl_ok += 1;
        } else |_| {
            msl_fail += 1;
            if (msl_fail <= 5) std.debug.print("  MSL FAIL: {s}\n", .{name});
        }

        // WGSL
        if (glslpp.spirvToWGSL(alloc, words, .{})) |result| {
            alloc.free(result);
            wgsl_ok += 1;
        } else |_| {
            wgsl_fail += 1;
            if (wgsl_fail <= 5) std.debug.print("  WGSL FAIL: {s}\n", .{name});
        }
    }

    std.debug.print("\n=== Cross-Validation Results ===\n", .{});
    std.debug.print("Total SPIR-V binaries: {d}\n\n", .{total});
    std.debug.print("HLSL: {d} OK, {d} FAIL ({d:.0}% pass)\n", .{ hlsl_ok, hlsl_fail, if (total > 0) @as(f64, @floatFromInt(hlsl_ok)) / @as(f64, @floatFromInt(total)) * 100.0 else 0.0 });
    std.debug.print("GLSL: {d} OK, {d} FAIL ({d:.0}% pass)\n", .{ glsl_ok, glsl_fail, if (total > 0) @as(f64, @floatFromInt(glsl_ok)) / @as(f64, @floatFromInt(total)) * 100.0 else 0.0 });
    std.debug.print("MSL:  {d} OK, {d} FAIL ({d:.0}% pass)\n", .{ msl_ok, msl_fail, if (total > 0) @as(f64, @floatFromInt(msl_ok)) / @as(f64, @floatFromInt(total)) * 100.0 else 0.0 });
    std.debug.print("WGSL: {d} OK, {d} FAIL ({d:.0}% pass)\n", .{ wgsl_ok, wgsl_fail, if (total > 0) @as(f64, @floatFromInt(wgsl_ok)) / @as(f64, @floatFromInt(total)) * 100.0 else 0.0 });
}
