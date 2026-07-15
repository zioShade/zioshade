const std = @import("std");
const zioshade = @import("zioshade");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try zioshade.compat.argsAlloc(alloc);
    defer zioshade.compat.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Usage: cross_validate_detail <spirv_bins_dir>\n", .{});
        return;
    }

    const dir_path = args[1];
    const entries = try zioshade.compat.walkDirAlloc(alloc, dir_path);
    defer zioshade.compat.freeWalkEntries(alloc, entries);

    var total: u32 = 0;
    var any_fail: u32 = 0;

    for (entries) |entry| {
        if (!entry.is_file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".spv")) continue;

        total += 1;
        const name = std.fs.path.basename(entry.path);

        const data = try zioshade.compat.readFileByPath(alloc, entry.path, 1024 * 1024);
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
        if (zioshade.spirvToHLSL(alloc, words, .{})) |result| {
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
        if (zioshade.spirvToGLSL(alloc, words, .{})) |result| {
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
        if (zioshade.spirvToMSL(alloc, words, .{})) |result| {
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
        if (zioshade.spirvToWGSL(alloc, words, .{})) |result| {
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
