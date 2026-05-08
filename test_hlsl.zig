// Test: compile a shadertoy-style shader through the full pipeline
const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("Usage: test_hlsl <shader.glsl>\n", .{});
        return;
    }

    // Read the shader
    const path = args[1];
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return;
    };
    defer file.close();
    const source = try file.readToEndAllocOptions(alloc, 10 * 1024 * 1024, null, .of(u8), 0);
    defer alloc.free(source);

    // Compile to SPIR-V
    std.debug.print("Compiling {s} to SPIR-V...\n", .{path});
    const spirv_words = glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment }) catch |err| {
        std.debug.print("SPIR-V compilation failed: {}\n", .{err});
        const detail = glslpp.last_compile_detail orelse .semantic_failed;
        std.debug.print("Detail: {s}\n", .{@tagName(detail)});
        return;
    };
    defer alloc.free(spirv_words);
    std.debug.print("SPIR-V: {} words ({} bytes)\n", .{ spirv_words.len, spirv_words.len * 4 });

    // Convert to HLSL
    std.debug.print("Converting SPIR-V to HLSL...\n", .{});
    const hlsl = glslpp.spirvToHLSL(alloc, spirv_words, .{
        .binding_shift = -1,
        .shader_model = 60,
    }) catch |err| {
        std.debug.print("HLSL conversion failed: {}\n", .{err});
        return;
    };
    defer alloc.free(hlsl);

    std.debug.print("\n=== HLSL Output ===\n{s}\n", .{hlsl});

    // Write to file if --save argument provided
    if (args.len > 2 and std.mem.eql(u8, args[2], "--save")) {
        const out_path = try std.fmt.allocPrint(alloc, "{s}.hlsl", .{path});
        defer alloc.free(out_path);
        const out_file = try std.fs.cwd().createFile(out_path, .{});
        defer out_file.close();
        try out_file.writeAll(hlsl);
        std.debug.print("Saved to {s}\n", .{out_path});
    }
}
