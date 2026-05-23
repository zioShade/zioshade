const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const alloc = gpa_impl.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print(
            \\glslpp — GLSL/SPIR-V shader compiler
            \\
            \\Usage: glslpp <command> <input> [options]
            \\
            \\Commands:
            \\  compile   Compile GLSL to SPIR-V binary
            \\  hlsl      Cross-compile GLSL/SPIR-V to HLSL
            \\  glsl      Cross-compile GLSL/SPIR-V to GLSL (round-trip)
            \\  msl       Cross-compile GLSL/SPIR-V to MSL
            \\  wgsl      Cross-compile GLSL/SPIR-V to WGSL
            \\  reflect   Reflect on SPIR-V binary
            \\  validate  Validate SPIR-V binary with spirv-val
            \\
            \\Options:
            \\  -o <path>        Output file (default: stdout)
            \\  --stage <stage>  Shader stage: vertex, fragment, compute, geometry (default: auto-detect)
            \\  --glsl-version   GLSL output version: 330, 410, 430, 450, 460 (default: 430)
            \\  --help           Show this help
            \\
        , .{});
        std.process.exit(2);
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) return;

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var stage_override: ?glslpp.Stage = null;
    var glsl_version: u32 = 430;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after -o", .{});
            output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--stage")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after --stage", .{});
            const s = args[i];
            if (std.mem.eql(u8, s, "vertex")) stage_override = .vertex
            else if (std.mem.eql(u8, s, "fragment")) stage_override = .fragment
            else if (std.mem.eql(u8, s, "compute")) stage_override = .compute
            else if (std.mem.eql(u8, s, "geometry")) stage_override = .geometry
            else if (std.mem.eql(u8, s, "tessellation_control")) stage_override = .tessellation_control
            else if (std.mem.eql(u8, s, "tessellation_evaluation")) stage_override = .tessellation_evaluation
            else fatal("unknown stage: {s}", .{s});
        } else if (std.mem.eql(u8, args[i], "--glsl-version")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after --glsl-version", .{});
            glsl_version = std.fmt.parseInt(u32, args[i], 10) catch fatal("invalid version: {s}", .{args[i]});
        } else {
            input_path = args[i];
        }
    }

    const input = input_path orelse fatal("missing input file", .{});
    const stage = stage_override orelse detectStage(input) orelse .fragment;
    const is_spv = std.mem.endsWith(u8, input, ".spv");

    if (std.mem.eql(u8, command, "compile")) {
        try doCompile(alloc, input, output_path, stage);
    } else if (std.mem.eql(u8, command, "hlsl")) {
        if (is_spv) try doSpvTo(alloc, input, output_path, .hlsl) else try doGlslTo(alloc, input, output_path, stage, .hlsl);
    } else if (std.mem.eql(u8, command, "glsl")) {
        if (is_spv) try doSpvToGlsl(alloc, input, output_path, glsl_version) else try doGlslToGlsl(alloc, input, output_path, stage, glsl_version);
    } else if (std.mem.eql(u8, command, "msl")) {
        if (is_spv) try doSpvTo(alloc, input, output_path, .msl) else try doGlslTo(alloc, input, output_path, stage, .msl);
    } else if (std.mem.eql(u8, command, "wgsl")) {
        if (is_spv) try doSpvTo(alloc, input, output_path, .wgsl) else try doGlslTo(alloc, input, output_path, stage, .wgsl);
    } else if (std.mem.eql(u8, command, "reflect")) {
        try doReflect(alloc, input);
    } else if (std.mem.eql(u8, command, "validate")) {
        try doValidate(alloc, input);
    } else {
        fatal("unknown command: {s}. See glslpp --help", .{command});
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn detectStage(path: []const u8) ?glslpp.Stage {
    if (std.mem.endsWith(u8, path, ".vert")) return .vertex;
    if (std.mem.endsWith(u8, path, ".frag")) return .fragment;
    if (std.mem.endsWith(u8, path, ".comp")) return .compute;
    if (std.mem.endsWith(u8, path, ".geom")) return .geometry;
    if (std.mem.endsWith(u8, path, ".tesc")) return .tessellation_control;
    if (std.mem.endsWith(u8, path, ".tese")) return .tessellation_evaluation;
    return null;
}

fn readSource(alloc: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    const raw = try std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
    defer alloc.free(raw);
    var buf = try std.ArrayListUnmanaged(u8).initCapacity(alloc, raw.len + 1);
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, raw);
    try buf.append(alloc, 0);
    const result = try buf.toOwnedSlice(alloc);
    return result[0 .. result.len - 1 :0];
}

fn readSpv(alloc: std.mem.Allocator, path: []const u8) ![]const u32 {
    const raw = try std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
    defer alloc.free(raw);
    if (raw.len < 20 or raw.len % 4 != 0) fatal("invalid SPIR-V binary: {s}", .{path});
    const n = raw.len / 4;
    const words = try alloc.alloc(u32, n);
    @memcpy(std.mem.sliceAsBytes(words)[0..raw.len], raw);
    return words;
}

fn writeOutput(output_path: ?[]const u8, data: []const u8) !void {
    if (output_path) |path| {
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
    } else {
        std.debug.print("{s}\n", .{data});
    }
}

const Backend = enum { hlsl, msl, wgsl };

fn doGlslTo(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, stage: glslpp.Stage, backend: Backend) !void {
    const source = try readSource(alloc, input);
    defer alloc.free(source);
    const result = switch (backend) {
        .hlsl => glslpp.compileGlslToHlsl(alloc, source, stage) catch |e| compileErr(e),
        .msl => glslpp.compileGlslToMsl(alloc, source, stage) catch |e| compileErr(e),
        .wgsl => glslpp.compileGlslToWgsl(alloc, source, stage) catch |e| compileErr(e),
    };
    defer alloc.free(result);
    try writeOutput(output, result);
}

fn doSpvTo(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, backend: Backend) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const result = switch (backend) {
        .hlsl => glslpp.spirvToHLSL(alloc, spv, .{}) catch |e| crossErr(e),
        .msl => glslpp.spirvToMSL(alloc, spv, .{}) catch |e| crossErr(e),
        .wgsl => glslpp.spirvToWGSL(alloc, spv, .{}) catch |e| crossErr(e),
    };
    defer alloc.free(result);
    try writeOutput(output, result);
}

fn doGlslToGlsl(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, stage: glslpp.Stage, version: u32) !void {
    const source = try readSource(alloc, input);
    defer alloc.free(source);
    const glsl = glslpp.compileGlslToGlslVersion(alloc, source, stage, version) catch |e| compileErr(e);
    defer alloc.free(glsl);
    try writeOutput(output, glsl);
}

fn doSpvToGlsl(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, version: u32) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const glsl = glslpp.spirvToGLSL(alloc, spv, .{ .version = version }) catch |e| crossErr(e);
    defer alloc.free(glsl);
    try writeOutput(output, glsl);
}

fn doCompile(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, stage: glslpp.Stage) !void {
    const source = try readSource(alloc, input);
    defer alloc.free(source);
    const spv = glslpp.compileToSPIRV(alloc, source, .{ .stage = stage }) catch |e| compileErr(e);
    defer alloc.free(spv);
    const bytes = std.mem.sliceAsBytes(spv);
    if (output) |path| {
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
        std.debug.print("SPIR-V: {d} words ({d} bytes) -> {s}\n", .{ spv.len, bytes.len, path });
    } else {
        std.debug.print("error: binary SPIR-V output requires -o <path>\n", .{});
        std.process.exit(2);
    }
}

fn doReflect(alloc: std.mem.Allocator, input: []const u8) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    var resources = glslpp.reflectSPIRV(alloc, spv) catch |err| {
        std.debug.print("error: reflection failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer resources.deinit(alloc);

    const p = std.debug.print;
    p("Entry Points: {d}\n", .{resources.entry_points.len});
    for (resources.entry_points) |ep| p("  {s} ({s})\n", .{ ep.name, @tagName(ep.stage) });
    p("Uniform Buffers: {d}\n", .{resources.uniform_buffers.len});
    for (resources.uniform_buffers) |ubo| p("  {s}: set={d} binding={d} size={d}\n", .{ ubo.name, ubo.set, ubo.binding, ubo.size });
    p("Storage Buffers: {d}\n", .{resources.storage_buffers.len});
    for (resources.storage_buffers) |sb| p("  {s}: set={d} binding={d} size={d}\n", .{ sb.name, sb.set, sb.binding, sb.size });
    p("Inputs: {d}\n", .{resources.inputs.len});
    for (resources.inputs) |inp| p("  {s}: location={d}\n", .{ inp.name, inp.location });
    p("Outputs: {d}\n", .{resources.outputs.len});
    for (resources.outputs) |out| p("  {s}: location={d}\n", .{ out.name, out.location });
    p("Sampled Images: {d}\n", .{resources.sampled_images.len});
    for (resources.sampled_images) |si| p("  {s}: set={d} binding={d}\n", .{ si.name, si.set, si.binding });
}

fn doValidate(alloc: std.mem.Allocator, input: []const u8) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const valid = glslpp.validateSPIRV(alloc, spv) catch false;
    if (valid) {
        std.debug.print("Validation passed: {s}\n", .{input});
    } else {
        std.debug.print("Validation failed: {s}\n", .{input});
        std.process.exit(1);
    }
}

fn compileErr(err: anyerror) noreturn {
    const detail = glslpp.last_compile_detail;
    std.debug.print("error: {s}", .{@errorName(err)});
    if (detail) |d| std.debug.print(" ({s})", .{@tagName(d)});
    std.debug.print("\n", .{});
    std.process.exit(1);
}

fn crossErr(err: anyerror) noreturn {
    std.debug.print("error: cross-compilation failed: {s}\n", .{@errorName(err)});
    std.process.exit(1);
}
