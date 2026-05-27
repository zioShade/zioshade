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
            \\  -o <path>             Output file (default: stdout)
            \\  --stage <stage>       Shader stage: vertex, fragment, compute, geometry, ...
            \\  --entry-point <name>  Entry point name (default: main)
            \\  -I <path>             Add include search path (repeatable)
            \\  -D<name>[=<value>]    Define preprocessor macro
            \\  --spec-const <ID=VAL> Override spec constant value (repeatable).
            \\                        VAL can be decimal int, 0x-hex, or true/false.
            \\  --glsl-version <ver>  GLSL output version: 330–460 (default: 430)
            \\  --shader-model <ver>  HLSL shader model: 50, 60 (default: 60)
            \\  --metal-version <ver> MSL version: 21, 24, 30 (default: 21)
            \\  --stdin               Read input from stdin
            \\  --help                Show this help
            \\
        , .{});
        std.process.exit(2);
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) return;

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var stage_override: ?glslpp.Stage = null;
    var entry_point: ?[]const u8 = null;
    var glsl_version: u32 = 430;
    var shader_model: u32 = 60;
    var metal_version: u32 = 21;
    var use_stdin = false;

    var include_paths = std.ArrayList([]const u8).initCapacity(alloc, 4) catch return;
    defer include_paths.deinit(alloc);

    var defines = std.ArrayList(glslpp.DefineOverride).initCapacity(alloc, 8) catch return;
    defer defines.deinit(alloc);

    var spec_overrides = std.ArrayList(glslpp.SpecOverride).initCapacity(alloc, 4) catch return;
    defer spec_overrides.deinit(alloc);

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
        } else if (std.mem.eql(u8, args[i], "--entry-point")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after --entry-point", .{});
            entry_point = args[i];
        } else if (std.mem.eql(u8, args[i], "-I")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after -I", .{});
            try include_paths.append(alloc, args[i]);
        } else if (std.mem.startsWith(u8, args[i], "-D")) {
            const def = args[i][2..];
            if (def.len == 0) fatal("empty define name after -D", .{});
            if (std.mem.indexOfScalar(u8, def, '=')) |eq_pos| {
                try defines.append(alloc, .{ .name = def[0..eq_pos], .value = def[eq_pos + 1 ..] });
            } else {
                try defines.append(alloc, .{ .name = def, .value = "1" });
            }
        } else if (std.mem.eql(u8, args[i], "--spec-const")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after --spec-const", .{});
            const arg = args[i];
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse fatal("--spec-const expects ID=VALUE (got '{s}')", .{arg});
            const id_str = arg[0..eq];
            const val_str = arg[eq + 1 ..];
            const sid = std.fmt.parseInt(u32, id_str, 10) catch fatal("--spec-const: invalid ID '{s}'", .{id_str});
            // Accept decimal int (signed or unsigned), hex 0x..., or "true"/"false".
            const value_u32: u32 = blk: {
                if (std.mem.eql(u8, val_str, "true")) break :blk 1;
                if (std.mem.eql(u8, val_str, "false")) break :blk 0;
                if (std.mem.startsWith(u8, val_str, "0x") or std.mem.startsWith(u8, val_str, "0X")) {
                    break :blk std.fmt.parseInt(u32, val_str[2..], 16) catch fatal("--spec-const: invalid hex value '{s}'", .{val_str});
                }
                if (std.mem.startsWith(u8, val_str, "-")) {
                    const iv = std.fmt.parseInt(i32, val_str, 10) catch fatal("--spec-const: invalid value '{s}'", .{val_str});
                    break :blk @bitCast(iv);
                }
                break :blk std.fmt.parseInt(u32, val_str, 10) catch fatal("--spec-const: invalid value '{s}'", .{val_str});
            };
            try spec_overrides.append(alloc, .{ .spec_id = sid, .value_u32 = value_u32 });
        } else if (std.mem.eql(u8, args[i], "--glsl-version")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after --glsl-version", .{});
            glsl_version = std.fmt.parseInt(u32, args[i], 10) catch fatal("invalid version: {s}", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--shader-model")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after --shader-model", .{});
            shader_model = std.fmt.parseInt(u32, args[i], 10) catch fatal("invalid shader model: {s}", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--metal-version")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after --metal-version", .{});
            metal_version = std.fmt.parseInt(u32, args[i], 10) catch fatal("invalid metal version: {s}", .{args[i]});
        } else if (std.mem.eql(u8, args[i], "--stdin")) {
            use_stdin = true;
        } else {
            input_path = args[i];
        }
    }

    const input = input_path orelse if (!use_stdin) fatal("missing input file (use --stdin to read from stdin)", .{}) else "stdin";
    const stage = stage_override orelse detectStage(input) orelse .fragment;
    const is_spv = std.mem.endsWith(u8, input, ".spv");

    // Publish parsed --spec-const overrides for compileWithDiagsOrExit to apply.
    cli_spec_overrides = spec_overrides.items;

    if (std.mem.eql(u8, command, "compile")) {
        const source = try readInput(alloc, input_path, use_stdin);
        defer alloc.free(source);
        try doCompile(alloc, source, output_path, stage, include_paths.items, defines.items);
    } else if (std.mem.eql(u8, command, "hlsl")) {
        if (is_spv and !use_stdin) {
            try doSpvToHlsl(alloc, input, output_path, entry_point, shader_model);
        } else {
            const source = try readInput(alloc, input_path, use_stdin);
            defer alloc.free(source);
            try doGlslToHlsl(alloc, source, output_path, stage, include_paths.items, defines.items, entry_point, shader_model);
        }
    } else if (std.mem.eql(u8, command, "glsl")) {
        if (is_spv and !use_stdin) {
            try doSpvToGlsl(alloc, input, output_path, glsl_version, entry_point);
        } else {
            const source = try readInput(alloc, input_path, use_stdin);
            defer alloc.free(source);
            try doGlslToGlsl(alloc, source, output_path, stage, glsl_version, include_paths.items, defines.items, entry_point);
        }
    } else if (std.mem.eql(u8, command, "msl")) {
        if (is_spv and !use_stdin) {
            try doSpvToMsl(alloc, input, output_path, entry_point, metal_version);
        } else {
            const source = try readInput(alloc, input_path, use_stdin);
            defer alloc.free(source);
            try doGlslToMsl(alloc, source, output_path, stage, include_paths.items, defines.items, entry_point, metal_version);
        }
    } else if (std.mem.eql(u8, command, "wgsl")) {
        if (is_spv and !use_stdin) {
            try doSpvToWgsl(alloc, input, output_path, entry_point);
        } else {
            const source = try readInput(alloc, input_path, use_stdin);
            defer alloc.free(source);
            try doGlslToWgsl(alloc, source, output_path, stage, include_paths.items, defines.items, entry_point);
        }
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
    if (std.mem.eql(u8, path, "stdin")) return null;
    // .v.glsl, .f.glsl, .c.glsl, .g.glsl conventions
    if (std.mem.endsWith(u8, path, ".v.glsl")) return .vertex;
    if (std.mem.endsWith(u8, path, ".f.glsl")) return .fragment;
    if (std.mem.endsWith(u8, path, ".c.glsl")) return .compute;
    if (std.mem.endsWith(u8, path, ".g.glsl")) return .geometry;
    // Standard extensions
    if (std.mem.endsWith(u8, path, ".vert")) return .vertex;
    if (std.mem.endsWith(u8, path, ".frag")) return .fragment;
    if (std.mem.endsWith(u8, path, ".comp")) return .compute;
    if (std.mem.endsWith(u8, path, ".geom")) return .geometry;
    if (std.mem.endsWith(u8, path, ".tesc")) return .tessellation_control;
    if (std.mem.endsWith(u8, path, ".tese")) return .tessellation_evaluation;
    return null;
}

fn readInput(alloc: std.mem.Allocator, path: ?[]const u8, use_stdin: bool) ![:0]const u8 {
    if (use_stdin or path == null) {
        const stdin_file = std.fs.File.stdin();
        const raw = try stdin_file.readToEndAlloc(alloc, 10 * 1024 * 1024);
        var buf = try std.ArrayListUnmanaged(u8).initCapacity(alloc, raw.len + 1);
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, raw);
        try buf.append(alloc, 0);
        alloc.free(raw);
        const result = try buf.toOwnedSlice(alloc);
        return result[0 .. result.len - 1 :0];
    }
    return readSource(alloc, path.?);
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
        const stdout_file = std.fs.File.stdout();
        try stdout_file.writeAll(data);
        try stdout_file.writeAll("\n");
    }
}

// ── Compile GLSL → SPIR-V ──────────────────────────────────────────

fn doCompile(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: glslpp.Stage, include_paths: []const []const u8, defines: []const glslpp.DefineOverride) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
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

// ── SPIR-V → HLSL ──────────────────────────────────────────────────

fn doSpvToHlsl(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, entry_point: ?[]const u8, shader_model: u32) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const result = glslpp.spirvToHLSL(alloc, spv, .{
        .shader_model = shader_model,
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

fn doGlslToHlsl(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: glslpp.Stage, include_paths: []const []const u8, defines: []const glslpp.DefineOverride, entry_point: ?[]const u8, shader_model: u32) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    const result = glslpp.spirvToHLSL(alloc, spv, .{
        .shader_model = shader_model,
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

// ── SPIR-V → GLSL ──────────────────────────────────────────────────

fn doSpvToGlsl(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, version: u32, entry_point: ?[]const u8) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const glsl = glslpp.spirvToGLSL(alloc, spv, .{
        .version = version,
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(glsl);
    try writeOutput(output, glsl);
}

fn doGlslToGlsl(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: glslpp.Stage, version: u32, include_paths: []const []const u8, defines: []const glslpp.DefineOverride, entry_point: ?[]const u8) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    const glsl = glslpp.spirvToGLSL(alloc, spv, .{
        .version = version,
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(glsl);
    try writeOutput(output, glsl);
}

// ── SPIR-V → MSL ───────────────────────────────────────────────────

fn doSpvToMsl(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, entry_point: ?[]const u8, metal_version: u32) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const result = glslpp.spirvToMSL(alloc, spv, .{
        .metal_version = metal_version,
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

fn doGlslToMsl(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: glslpp.Stage, include_paths: []const []const u8, defines: []const glslpp.DefineOverride, entry_point: ?[]const u8, metal_version: u32) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    const result = glslpp.spirvToMSL(alloc, spv, .{
        .metal_version = metal_version,
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

// ── SPIR-V → WGSL ──────────────────────────────────────────────────

fn doSpvToWgsl(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, entry_point: ?[]const u8) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const result = glslpp.spirvToWGSL(alloc, spv, .{
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

fn doGlslToWgsl(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: glslpp.Stage, include_paths: []const []const u8, defines: []const glslpp.DefineOverride, entry_point: ?[]const u8) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    const result = glslpp.spirvToWGSL(alloc, spv, .{
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

// ── Reflect / Validate ─────────────────────────────────────────────

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
    const ctx = glslpp.lastErrorCtx();
    if (ctx) |c| std.debug.print(": {s}", .{c});
    std.debug.print("\n", .{});
    std.process.exit(1);
}

/// Print one diagnostic in glslang-style `path:line:col: kind: message` format.
fn printDiagnostic(d: glslpp.diagnostic.Diagnostic) void {
    const kind_str: []const u8 = switch (d.kind) {
        .@"error" => "error",
        .warning => "warning",
        .note => "note",
    };
    if (d.path.len > 0) {
        std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{ d.path, d.line, d.column, kind_str, d.message });
    } else {
        std.debug.print("{d}:{d}: {s}: {s}\n", .{ d.line, d.column, kind_str, d.message });
    }
}

/// Module-scope override list populated by `--spec-const ID=VALUE` parsing in
/// `main`. Single-threaded CLI usage justifies the global; library callers
/// should use `glslpp.compileToSPIRVWithSpecOverrides` directly.
var cli_spec_overrides: []const glslpp.SpecOverride = &.{};

/// Compile GLSL to SPIR-V, surfacing every collected Diagnostic to stderr
/// in glslang-style format before exiting on failure. Used by all CLI
/// commands that take GLSL source as input. Also applies any
/// `cli_spec_overrides` populated from `--spec-const ID=VALUE` flags.
fn compileWithDiagsOrExit(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    opts: glslpp.CompileOptions,
) []const u32 {
    var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    const spv = glslpp.compileToSPIRVWithDiagnostics(alloc, source, opts, &diags) catch |e| {
        for (diags.items) |d| printDiagnostic(d);
        compileErr(e);
    };
    if (cli_spec_overrides.len == 0) return spv;
    // Apply overrides (mutates the SPIR-V in a new buffer; frees the
    // intermediate). On allocation failure we fall back to the unmodified
    // SPIR-V — better than crashing the CLI.
    const out = alloc.alloc(u32, spv.len) catch return spv;
    @memcpy(out, spv);
    alloc.free(spv);
    glslpp.applySpecOverrides(out, cli_spec_overrides);
    return out;
}

fn crossErr(err: anyerror) noreturn {
    std.debug.print("error: cross-compilation failed: {s}\n", .{@errorName(err)});
    std.process.exit(1);
}
