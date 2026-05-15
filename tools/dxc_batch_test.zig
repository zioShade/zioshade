const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const dxc_path = if (args.len > 1) args[1] else "C:/VulkanSDK/1.4.341.1/Bin/dxc.exe";
    const spv_dir = if (args.len > 2) args[2] else "tests/spirv_bins";
    const sm: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 60;

    var dir = try std.fs.cwd().openDir(spv_dir, .{ .iterate = true });
    defer dir.close();

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".spv")) continue;

        // Read SPIR-V binary
        const spv_data = dir.readFileAlloc(alloc, name, 1024 * 1024) catch |err| {
            std.debug.print("SKIP {s}: read error {}\n", .{ name, err });
            skipped += 1;
            continue;
        };
        const spv_u32_len = spv_data.len / 4;
        const spv = @as([*]const u32, @ptrCast(@alignCast(spv_data.ptr)))[0..spv_u32_len];

        // Convert to HLSL
        const hlsl = glslpp.spirvToHLSL(alloc, spv, .{ .shader_model = sm }) catch |err| {
            std.debug.print("SKIP {s}: cross-compile error {}\n", .{ name, err });
            skipped += 1;
            alloc.free(spv_data);
            continue;
        };
        defer alloc.free(hlsl);
        defer alloc.free(spv_data);

        // Write HLSL to temp file
        const tmp_path = "tmp_hlsl_test.hlsl";
        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
        try tmp_file.writeAll(hlsl);
        tmp_file.close();

        // Run DXC
        const sm_str = try std.fmt.allocPrint(alloc, "ps_{d}_{d}", .{ sm / 10, sm % 10 });
        defer alloc.free(sm_str);
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ dxc_path, "-T", sm_str, "-E", "main", tmp_path },
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);

        if (result.term.Exited == 0) {
            passed += 1;
            std.debug.print("PASS {s}\n", .{name});
        } else {
            failed += 1;
            // Extract first error line
            const stderr_str = result.stderr;
            const first_err: []const u8 = if (std.mem.indexOf(u8, stderr_str, "error:")) |idx|
                stderr_str[idx..@min(idx + 120, stderr_str.len)]
            else
                stderr_str[0..@min(80, stderr_str.len)];
            std.debug.print("FAIL {s}: {s}\n", .{ name, first_err });
        }

        // Clean up temp file
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    std.debug.print("\n=== DXC Summary (SM {d}.{d}) ===\n", .{ sm / 10, sm % 10 });
    std.debug.print("PASS: {d}\nFAIL: {d}\nSKIP: {d}\n", .{ passed, failed, skipped });
}
