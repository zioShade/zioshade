const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Usage: cross_validate_detail <spirv_bins_dir>\n", .{});
        return;
    }

    const dir_path = args[1];
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var total: u32 = 0;
    var any_fail: u32 = 0;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".spv")) continue;

        total += 1;
        const name = entry.basename;

        const file = try dir.openFile(entry.path, .{});
        defer file.close();
        const data = try file.readToEndAlloc(alloc, 1024 * 1024);
        defer alloc.free(data);

        if (data.len < 20 or data.len % 4 != 0) continue;
        const word_count = data.len / 4;
        const words = try alloc.alloc(u32, word_count);
        defer alloc.free(words);
        for (0..word_count) |i| {
            words[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
        }

        var file_had_error = false;

        // HLSL
        if (glslpp.spirvToHLSL(alloc, words, .{})) |result| {
            alloc.free(result);
        } else |_| {
            if (!file_had_error) {
                std.debug.print("  {s}:\n", .{name});
                file_had_error = true;
                any_fail += 1;
            }
            std.debug.print("    HLSL: FAILED\n", .{});
        }

        // GLSL
        if (glslpp.spirvToGLSL(alloc, words, .{})) |result| {
            alloc.free(result);
        } else |_| {
            if (!file_had_error) {
                std.debug.print("  {s}:\n", .{name});
                file_had_error = true;
                any_fail += 1;
            }
            std.debug.print("    GLSL: FAILED\n", .{});
        }

        // MSL
        if (glslpp.spirvToMSL(alloc, words, .{})) |result| {
            alloc.free(result);
        } else |_| {
            if (!file_had_error) {
                std.debug.print("  {s}:\n", .{name});
                file_had_error = true;
                any_fail += 1;
            }
            std.debug.print("    MSL: FAILED\n", .{});
        }

        // WGSL
        if (glslpp.spirvToWGSL(alloc, words, .{})) |result| {
            alloc.free(result);
        } else |_| {
            if (!file_had_error) {
                std.debug.print("  {s}:\n", .{name});
                file_had_error = true;
                any_fail += 1;
            }
            std.debug.print("    WGSL: FAILED\n", .{});
        }
    }

    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Total: {d}, All-pass: {d}, Any-fail: {d}\n", .{ total, total - any_fail, any_fail });
}
