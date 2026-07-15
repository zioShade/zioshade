const std = @import("std");
const zioshade = @import("zioshade");
// Use the public cross-compile API — the internal spirv_to_* modules are not
// exported from src/root.zig, so referencing them broke the 0.15.2 build.
const hlsl = struct {
    const spirvToHLSL = zioshade.spirvToHLSL;
};
const glsl_backend = struct {
    const spirvToGLSL = zioshade.spirvToGLSL;
};
const msl = struct {
    const spirvToMSL = zioshade.spirvToMSL;
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{ .never_unmap = true, .retain_metadata = false }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const dirs = [_][]const u8{ "tests/glslang-430", "tests/spirv-cross", "tests/ghostty" };

    var total: u32 = 0;
    var unhandled_count: u32 = 0;

    for (&dirs) |dir_path| {
        const entries = zioshade.compat.walkDirAlloc(alloc, dir_path) catch continue;
        defer zioshade.compat.freeWalkEntries(alloc, entries);

        for (entries) |entry| {
            if (!entry.is_file) continue;
            const basename = std.fs.path.basename(entry.path);
            const ext = std.fs.path.extension(basename);
            if (!std.mem.eql(u8, ext, ".frag") and !std.mem.eql(u8, ext, ".vert") and
                !std.mem.eql(u8, ext, ".comp") and !std.mem.eql(u8, ext, ".glsl") and
                !std.mem.eql(u8, ext, ".v.glsl") and !std.mem.eql(u8, ext, ".f.glsl"))
                continue;
            if (std.mem.indexOf(u8, basename, ".error.") != null) continue;
            if (std.mem.indexOf(u8, basename, ".asm.") != null) continue;
            if (std.mem.indexOf(u8, basename, ".nocompat.") != null) continue;

            // `entry.path` is already the cwd-relative dir_path joined with the
            // walk-relative path, so it is the full path to read/report.
            const path = entry.path;

            const source_raw = zioshade.compat.readFileByPath(alloc, path, 10 * 1024 * 1024) catch continue;
            const source = try alloc.dupeZ(u8, source_raw);
            alloc.free(source_raw);
            defer alloc.free(source);

            if (std.mem.indexOf(u8, source, "void main") == null and
                std.mem.indexOf(u8, source, "void mainImage") == null)
                continue;

            const stage: zioshade.Stage = if (std.mem.endsWith(u8, path, ".vert") or std.mem.endsWith(u8, path, ".v.glsl"))
                .vertex
            else if (std.mem.endsWith(u8, path, ".comp"))
                .compute
            else
                .fragment;

            const spirv = zioshade.compileToSPIRV(alloc, source, .{ .stage = stage }) catch continue;
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
