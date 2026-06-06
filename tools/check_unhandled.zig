const std = @import("std");
const glslpp = @import("glslpp");
// Use the public cross-compile API — the internal spirv_to_* modules are not
// exported from src/root.zig, so referencing them broke the 0.15.2 build.
const hlsl = struct {
    const spirvToHLSL = glslpp.spirvToHLSL;
};
const glsl_backend = struct {
    const spirvToGLSL = glslpp.spirvToGLSL;
};
const msl = struct {
    const spirvToMSL = glslpp.spirvToMSL;
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .never_unmap = true, .retain_metadata = false }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const dirs = [_][]const u8{ "tests/glslang-430", "tests/spirv-cross", "tests/ghostty" };

    var total: u32 = 0;
    var unhandled_count: u32 = 0;

    for (&dirs) |dir_path| {
        const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        var walker = try dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            const ext = std.fs.path.extension(entry.basename);
            if (!std.mem.eql(u8, ext, ".frag") and !std.mem.eql(u8, ext, ".vert") and
                !std.mem.eql(u8, ext, ".comp") and !std.mem.eql(u8, ext, ".glsl") and
                !std.mem.eql(u8, ext, ".v.glsl") and !std.mem.eql(u8, ext, ".f.glsl"))
                continue;
            if (std.mem.indexOf(u8, entry.basename, ".error.") != null) continue;
            if (std.mem.indexOf(u8, entry.basename, ".asm.") != null) continue;
            if (std.mem.indexOf(u8, entry.basename, ".nocompat.") != null) continue;

            var path_buf: [1024]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.path });

            const file = std.fs.cwd().openFile(path, .{}) catch continue;
            defer file.close();
            const source_raw = file.readToEndAlloc(alloc, 10 * 1024 * 1024) catch continue;
            const source = try alloc.dupeZ(u8, source_raw);
            alloc.free(source_raw);
            defer alloc.free(source);

            if (std.mem.indexOf(u8, source, "void main") == null and
                std.mem.indexOf(u8, source, "void mainImage") == null)
                continue;

            const stage: glslpp.Stage = if (std.mem.endsWith(u8, path, ".vert") or std.mem.endsWith(u8, path, ".v.glsl"))
                .vertex
            else if (std.mem.endsWith(u8, path, ".comp"))
                .compute
            else
                .fragment;

            const spirv = glslpp.compileToSPIRV(alloc, source, .{ .stage = stage }) catch continue;
            defer alloc.free(spirv);

            total += 1;

            // Check HLSL
            if (hlsl.spirvToHLSL(alloc, spirv, .{})) |result| {
                defer alloc.free(result);
                if (std.mem.indexOf(u8, result, "unhandled op")) |_| {
                    std.debug.print("  UNHANDLED OP [HLSL] {s}\n", .{path});
                    unhandled_count += 1;
                }
                if (std.mem.indexOf(u8, result, "unhandled std450")) |_| {
                    std.debug.print("  UNHANDLED STD450 [HLSL] {s}\n", .{path});
                    unhandled_count += 1;
                }
            } else |_| {}

            // Check GLSL
            if (glsl_backend.spirvToGLSL(alloc, spirv, .{})) |result| {
                defer alloc.free(result);
                if (std.mem.indexOf(u8, result, "unhandled op")) |_| {
                    std.debug.print("  UNHANDLED OP [GLSL] {s}\n", .{path});
                    unhandled_count += 1;
                }
                if (std.mem.indexOf(u8, result, "unhandled std450")) |_| {
                    std.debug.print("  UNHANDLED STD450 [GLSL] {s}\n", .{path});
                    unhandled_count += 1;
                }
            } else |_| {}

            // Check MSL
            if (msl.spirvToMSL(alloc, spirv, .{})) |result| {
                defer alloc.free(result);
                if (std.mem.indexOf(u8, result, "unhandled op")) |_| {
                    std.debug.print("  UNHANDLED OP [MSL] {s}\n", .{path});
                    unhandled_count += 1;
                }
                if (std.mem.indexOf(u8, result, "unhandled std450")) |_| {
                    std.debug.print("  UNHANDLED STD450 [MSL] {s}\n", .{path});
                    unhandled_count += 1;
                }
            } else |_| {}
        }
    }

    std.debug.print("\nTotal: {d} shaders, {d} unhandled instances\n", .{ total, unhandled_count });
}
