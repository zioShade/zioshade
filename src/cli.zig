const std = @import("std");
const compat = zioshade.compat;
const zioshade = @import("zioshade");

// The main entry point differs by Zig version: 0.16 passes command-line args
// and environment through a `std.process.Init.Minimal` parameter, while 0.15
// exposes them via the global `std.process.argsAlloc`. Select the matching
// signature at comptime so only the version-correct one is analyzed; both hand
// off to `run` once `compat` has captured whatever init state it needs.
pub const main = if (compat.is_0_16) main_0_16 else main_0_15;

fn main_0_15() !void {
    return run();
}

fn main_0_16(init: compat.MainInit) !void {
    compat.setMainInit(init);
    return run();
}

// The usage text lives here (not inline in run) so BOTH entry points reach it:
// zero arguments (exit 2, the historical behaviour) and --help/-h (exit 0).
fn printUsage() void {
    std.debug.print(
        \\zioshade - GLSL/SPIR-V shader compiler
        \\
        \\Usage: zioshade <command> <input> [options]
        \\
        \\Commands:
        \\  compile   Compile GLSL to SPIR-V binary
        \\  hlsl      Cross-compile GLSL/SPIR-V to HLSL
        \\  glsl      Cross-compile GLSL/SPIR-V to GLSL (round-trip)
        \\  msl       Cross-compile GLSL/SPIR-V to MSL
        \\  wgsl      Cross-compile GLSL/SPIR-V to WGSL
        \\  reflect   Reflect on SPIR-V binary (add --json for spirv-cross-style JSON)
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
        \\  --glsl-version <ver>  GLSL output version: 330-460 (default: 430)
        \\  --shader-model <ver>  HLSL shader model: 50, 60 (default: 60)
        \\  --metal-version <ver> MSL version: 21, 24, 30 (default: 21)
        \\  --msl-argument-buffers
        \\                        Emit Metal 2+ argument buffers (spvDescriptorSetBufferN)
        \\  --bind <set:bind:reg> Remap a (set, binding) to an explicit HLSL register /
        \\                        MSL slot number (repeatable). Class b/t/s/u (HLSL) or
        \\                        buffer/texture/sampler (MSL) is inferred from the type.
        \\  --json                (reflect) Emit spirv-cross-style reflection JSON
        \\  --stdin               Read input from stdin
        \\  --help                Show this help
        \\  --version             Print the version and exit
        \\
    , .{});
}

fn run() !void {
    var gpa_impl = compat.Gpa(.{}){};
    defer _ = gpa_impl.deinit();
    const alloc = gpa_impl.allocator();

    const args = try compat.argsAlloc(alloc);
    defer compat.argsFree(alloc, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(2);
    }

    const command = args[1];
    // --help now prints the usage instead of exiting silently: the text was only
    // reachable with ZERO arguments, so `zioshade --help` printed nothing (and a
    // user could not discover the commands without reading the source).
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }
    // Printed from src/version.zig, kept in sync with build.zig.zon's .version by
    // tools/check_version_sync.py (a CI gate): a deployed binary must be traceable
    // back to the tag it was cut from for bug reports to mean anything.
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        std.debug.print("zioshade {s}\n", .{@import("version.zig").version_string});
        return;
    }

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var stage_override: ?zioshade.Stage = null;
    var entry_point: ?[]const u8 = null;
    var glsl_version: u32 = 430;
    var shader_model: u32 = 60;
    var metal_version: u32 = 21;
    var msl_arg_buffers = false;
    var use_stdin = false;
    var json_output = false;

    var include_paths = std.ArrayList([]const u8).initCapacity(alloc, 4) catch return;
    defer include_paths.deinit(alloc);

    var defines = std.ArrayList(zioshade.DefineOverride).initCapacity(alloc, 8) catch return;
    defer defines.deinit(alloc);

    var spec_overrides = std.ArrayList(zioshade.SpecOverride).initCapacity(alloc, 4) catch return;
    defer spec_overrides.deinit(alloc);
    var bind_overrides = std.ArrayList(BindOverride).initCapacity(alloc, 4) catch return;
    defer bind_overrides.deinit(alloc);

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
            if (std.mem.eql(u8, s, "vertex")) stage_override = .vertex else if (std.mem.eql(u8, s, "fragment")) stage_override = .fragment else if (std.mem.eql(u8, s, "compute")) stage_override = .compute else if (std.mem.eql(u8, s, "geometry")) stage_override = .geometry else if (std.mem.eql(u8, s, "tessellation_control")) stage_override = .tessellation_control else if (std.mem.eql(u8, s, "tessellation_evaluation")) stage_override = .tessellation_evaluation else if (std.mem.eql(u8, s, "mesh")) stage_override = .mesh else if (std.mem.eql(u8, s, "task")) stage_override = .task else if (std.mem.eql(u8, s, "raygen")) stage_override = .raygen else if (std.mem.eql(u8, s, "closesthit")) stage_override = .closesthit else if (std.mem.eql(u8, s, "miss")) stage_override = .miss else if (std.mem.eql(u8, s, "intersection")) stage_override = .intersection else if (std.mem.eql(u8, s, "anyhit")) stage_override = .anyhit else if (std.mem.eql(u8, s, "callable")) stage_override = .callable else fatal("unknown stage: {s}", .{s});
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
        } else if (std.mem.eql(u8, args[i], "--bind")) {
            i += 1;
            if (i >= args.len) fatal("missing argument after --bind (expected set:binding:register)", .{});
            const arg = args[i];
            var it = std.mem.splitScalar(u8, arg, ':');
            const set_str = it.next() orelse fatal("--bind expects set:binding:register (got '{s}')", .{arg});
            const bind_str = it.next() orelse fatal("--bind expects set:binding:register (got '{s}')", .{arg});
            const reg_str = it.next() orelse fatal("--bind expects set:binding:register (got '{s}')", .{arg});
            if (it.next() != null) fatal("--bind expects set:binding:register (got '{s}')", .{arg});
            bind_overrides.append(alloc, .{
                .set = std.fmt.parseInt(u32, set_str, 10) catch fatal("--bind: invalid set '{s}'", .{set_str}),
                .binding = std.fmt.parseInt(u32, bind_str, 10) catch fatal("--bind: invalid binding '{s}'", .{bind_str}),
                .reg = std.fmt.parseInt(u32, reg_str, 10) catch fatal("--bind: invalid register '{s}'", .{reg_str}),
            }) catch return;
        } else if (std.mem.eql(u8, args[i], "--msl-argument-buffers")) {
            msl_arg_buffers = true;
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_output = true;
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
    cli_resource_bindings = bind_overrides.items;
    cli_input_path = input; // stamp path:line:col onto compile diagnostics

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
            try doSpvToMsl(alloc, input, output_path, entry_point, metal_version, msl_arg_buffers);
        } else {
            const source = try readInput(alloc, input_path, use_stdin);
            defer alloc.free(source);
            try doGlslToMsl(alloc, source, output_path, stage, include_paths.items, defines.items, entry_point, metal_version, msl_arg_buffers);
        }
    } else if (std.mem.eql(u8, command, "wgsl")) {
        if (is_spv and !use_stdin) {
            try doSpvToWgsl(alloc, input, output_path, entry_point);
        } else {
            const source = try readInput(alloc, input_path, use_stdin);
            defer alloc.free(source);
            try doGlslToWgsl(alloc, source, output_path, stage, include_paths.items, defines.items, entry_point);
        }
    } else if (std.mem.eql(u8, command, "spirv")) {
        // Dump zioshade's OWN frontend SPIR-V (GLSL -> SPIR-V, no backend). Writes
        // the binary little-endian u32 words; pipe through `spirv-dis` to read. Used
        // to inspect what the frontend generates when a backend bug is suspected to
        // originate upstream (frontend) -- e.g. spec-const struct members, integer
        // arithmetic builtin lowering.
        const source = try readInput(alloc, input_path, use_stdin);
        defer alloc.free(source);
        try doGlslToSpvDump(alloc, source, output_path, stage, include_paths.items, defines.items);
    } else if (std.mem.eql(u8, command, "reflect")) {
        try doReflect(alloc, input, json_output);
    } else if (std.mem.eql(u8, command, "validate")) {
        try doValidate(alloc, input);
    } else {
        fatal("unknown command: {s}. See zioshade --help", .{command});
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn detectStage(path: []const u8) ?zioshade.Stage {
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
        const raw = try compat.readStdinAlloc(alloc, 10 * 1024 * 1024);
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
    const raw = compat.readFileByPath(alloc, path, 10 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => fatal("cannot open '{s}'", .{path}),
        else => fatal("cannot read '{s}': {s}", .{ path, @errorName(err) }),
    };
    defer alloc.free(raw);
    var buf = try std.ArrayListUnmanaged(u8).initCapacity(alloc, raw.len + 1);
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, raw);
    try buf.append(alloc, 0);
    const result = try buf.toOwnedSlice(alloc);
    return result[0 .. result.len - 1 :0];
}

fn readSpv(alloc: std.mem.Allocator, path: []const u8) ![]const u32 {
    const raw = compat.readFileByPath(alloc, path, 10 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => fatal("cannot open '{s}'", .{path}),
        else => fatal("cannot read '{s}': {s}", .{ path, @errorName(err) }),
    };
    defer alloc.free(raw);
    if (raw.len < 20 or raw.len % 4 != 0) fatal("invalid SPIR-V binary: {s}", .{path});
    const n = raw.len / 4;
    const words = try alloc.alloc(u32, n);
    @memcpy(std.mem.sliceAsBytes(words)[0..raw.len], raw);
    return words;
}

fn writeOutput(output_path: ?[]const u8, data: []const u8) !void {
    if (output_path) |path| {
        try compat.writeFileByPath(std.heap.page_allocator, path, data);
    } else {
        try compat.writeStdout(data);
        try compat.writeStdout("\n");
    }
}

// ── Compile GLSL → SPIR-V ──────────────────────────────────────────

fn doCompile(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: zioshade.Stage, include_paths: []const []const u8, defines: []const zioshade.DefineOverride) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    const bytes = std.mem.sliceAsBytes(spv);
    if (output) |path| {
        try compat.writeFileByPath(alloc, path, bytes);
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
    const result = zioshade.spirvToHLSL(alloc, spv, .{
        .shader_model = shader_model,
        .entry_point_name = entry_point orelse "main",
        .resource_bindings = hlslBindings(alloc),
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

fn doGlslToHlsl(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: zioshade.Stage, include_paths: []const []const u8, defines: []const zioshade.DefineOverride, entry_point: ?[]const u8, shader_model: u32) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    const result = zioshade.spirvToHLSL(alloc, spv, .{
        .shader_model = shader_model,
        .entry_point_name = entry_point orelse "main",
        .resource_bindings = hlslBindings(alloc),
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

// ── SPIR-V → GLSL ──────────────────────────────────────────────────

fn doSpvToGlsl(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, version: u32, entry_point: ?[]const u8) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const glsl = zioshade.spirvToGLSL(alloc, spv, .{
        .version = version,
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(glsl);
    try writeOutput(output, glsl);
}

fn doGlslToGlsl(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: zioshade.Stage, version: u32, include_paths: []const []const u8, defines: []const zioshade.DefineOverride, entry_point: ?[]const u8) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    const glsl = zioshade.spirvToGLSL(alloc, spv, .{
        .version = version,
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(glsl);
    try writeOutput(output, glsl);
}

// ── SPIR-V → MSL ───────────────────────────────────────────────────

fn doSpvToMsl(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, entry_point: ?[]const u8, metal_version: u32, argument_buffers: bool) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const result = zioshade.spirvToMSL(alloc, spv, .{
        .metal_version = metal_version,
        .entry_point_name = entry_point orelse "main",
        .argument_buffers = argument_buffers,
        .resource_bindings = mslBindings(alloc),
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

fn doGlslToMsl(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: zioshade.Stage, include_paths: []const []const u8, defines: []const zioshade.DefineOverride, entry_point: ?[]const u8, metal_version: u32, argument_buffers: bool) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    const result = zioshade.spirvToMSL(alloc, spv, .{
        .metal_version = metal_version,
        .entry_point_name = entry_point orelse "main",
        .argument_buffers = argument_buffers,
        .resource_bindings = mslBindings(alloc),
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

// ── GLSL → SPIR-V dump (frontend output, no backend) ───────────────

fn doGlslToSpvDump(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: zioshade.Stage, include_paths: []const []const u8, defines: []const zioshade.DefineOverride) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    // Write the SPIR-V binary (little-endian u32 words -> bytes). Pipe through
    // `spirv-dis` to read it.
    const bytes = std.mem.sliceAsBytes(spv);
    if (output) |path| {
        try compat.writeFileByPath(std.heap.page_allocator, path, bytes);
    } else {
        try compat.writeStdout(bytes);
    }
}

// ── SPIR-V → WGSL ──────────────────────────────────────────────────

fn doSpvToWgsl(alloc: std.mem.Allocator, input: []const u8, output: ?[]const u8, entry_point: ?[]const u8) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    const result = zioshade.spirvToWGSL(alloc, spv, .{
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

fn doGlslToWgsl(alloc: std.mem.Allocator, source: [:0]const u8, output: ?[]const u8, stage: zioshade.Stage, include_paths: []const []const u8, defines: []const zioshade.DefineOverride, entry_point: ?[]const u8) !void {
    const spv = compileWithDiagsOrExit(alloc, source, .{
        .stage = stage,
        .include_paths = include_paths,
        .defines = defines,
    });
    defer alloc.free(spv);
    const result = zioshade.spirvToWGSL(alloc, spv, .{
        .entry_point_name = entry_point orelse "main",
    }) catch |e| crossErr(e);
    defer alloc.free(result);
    try writeOutput(output, result);
}

// ── Reflect / Validate ─────────────────────────────────────────────

/// Print buffer-block member layout metadata (offset / strides / runtime /
/// access quals), recursing into nested struct members (#177).
fn printMembers(members: []const zioshade.reflection.Member, indent: usize) void {
    const p = std.debug.print;
    for (members) |m| {
        for (0..indent) |_| p("  ", .{});
        p("  .{s}: offset={d} size={d}", .{ m.name, m.offset, m.size });
        if (m.matrix_stride != 0) p(" matrix_stride={d} {s}", .{ m.matrix_stride, if (m.is_row_major) "row_major" else "col_major" });
        if (m.array_stride != 0 or m.is_runtime_array or m.array_dim != 0) {
            if (m.is_runtime_array) {
                p(" array[] (runtime) array_stride={d}", .{m.array_stride});
            } else {
                p(" array[{d}] array_stride={d}", .{ m.array_dim, m.array_stride });
            }
        }
        if (m.coherent) p(" coherent", .{});
        if (m.is_volatile) p(" volatile", .{});
        if (m.restrict) p(" restrict", .{});
        p("\n", .{});
        if (m.members) |inner| printMembers(inner, indent + 1);
    }
}

fn doReflect(alloc: std.mem.Allocator, input: []const u8, json_output: bool) !void {
    const spv = try readSpv(alloc, input);
    defer alloc.free(spv);
    var resources = zioshade.reflectSPIRV(alloc, spv) catch |err| {
        std.debug.print("error: reflection failed: {}\n", .{err});
        std.process.exit(1);
    };
    defer resources.deinit(alloc);

    // `--json`: emit the spirv-cross-style reflection JSON to stdout instead of
    // the human-readable text dump (#177 Item 2).
    if (json_output) {
        const json = zioshade.reflectionToJson(alloc, &resources) catch |err| {
            std.debug.print("error: JSON serialization failed: {}\n", .{err});
            std.process.exit(1);
        };
        defer alloc.free(json);
        try writeOutput(null, json);
        return;
    }

    const p = std.debug.print;
    p("Entry Points: {d}\n", .{resources.entry_points.len});
    for (resources.entry_points) |ep| p("  {s} ({s})\n", .{ ep.name, @tagName(ep.stage) });
    p("Uniform Buffers: {d}\n", .{resources.uniform_buffers.len});
    for (resources.uniform_buffers) |ubo| {
        p("  {s}: set={d} binding={d} size={d} block_size={d}\n", .{ ubo.name, ubo.set, ubo.binding, ubo.size, ubo.block_size });
        printMembers(ubo.members, 0);
    }
    p("Storage Buffers: {d}\n", .{resources.storage_buffers.len});
    for (resources.storage_buffers) |sb| {
        p("  {s}: set={d} binding={d} size={d} block_size={d}{s}{s}{s}{s}{s}\n", .{
            sb.name,                              sb.set,                                 sb.binding,                           sb.size,                                 sb.block_size,
            if (sb.readonly) " readonly" else "", if (sb.writeonly) " writeonly" else "", if (sb.coherent) " coherent" else "", if (sb.is_volatile) " volatile" else "", if (sb.restrict) " restrict" else "",
        });
        printMembers(sb.members, 0);
    }
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
    const valid = zioshade.validateSPIRV(alloc, spv) catch false;
    if (valid) {
        std.debug.print("Validation passed: {s}\n", .{input});
    } else {
        std.debug.print("Validation failed: {s}\n", .{input});
        std.process.exit(1);
    }
}

fn compileErr(err: anyerror) noreturn {
    const detail = zioshade.last_compile_detail;
    std.debug.print("error: {s}", .{@errorName(err)});
    if (detail) |d| std.debug.print(" ({s})", .{@tagName(d)});
    const ctx = zioshade.lastErrorCtx();
    if (ctx) |c| std.debug.print(": {s}", .{c});
    std.debug.print("\n", .{});
    std.process.exit(1);
}

/// Print one diagnostic in glslang-style `path:line:col: kind: message` format.
fn printDiagnostic(d: zioshade.diagnostic.Diagnostic) void {
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
/// should use `zioshade.compileToSPIRVWithSpecOverrides` directly.
var cli_spec_overrides: []const zioshade.SpecOverride = &.{};

/// Parsed `--bind set:binding:reg` descriptor-remap overrides (G6). Backend-
/// neutral triples; converted to HlslCompileOptions.resource_bindings /
/// MslCompileOptions.resource_bindings at each cross-compile call site.
const BindOverride = struct { set: u32, binding: u32, reg: u32 };
var cli_resource_bindings: []const BindOverride = &.{};

/// Resolved input path (or "stdin") for the current CLI invocation, published by `main`
/// so compileWithDiagsOrExit can stamp `path:line:col` onto diagnostics. Module-scope for
/// the same single-threaded-CLI reason as cli_spec_overrides above.
var cli_input_path: []const u8 = "";

/// Build the HLSL `resource_bindings` slice from the CLI `--bind` overrides.
fn hlslBindings(alloc: std.mem.Allocator) []const zioshade.ResourceBinding {
    if (cli_resource_bindings.len == 0) return &.{};
    const out = alloc.alloc(zioshade.ResourceBinding, cli_resource_bindings.len) catch return &.{};
    for (cli_resource_bindings, 0..) |b, i| out[i] = .{ .set = b.set, .binding = b.binding, .register = b.reg };
    return out;
}

/// Build the MSL `resource_bindings` slice from the CLI `--bind` overrides.
fn mslBindings(alloc: std.mem.Allocator) []const zioshade.MslResourceBinding {
    if (cli_resource_bindings.len == 0) return &.{};
    const out = alloc.alloc(zioshade.MslResourceBinding, cli_resource_bindings.len) catch return &.{};
    for (cli_resource_bindings, 0..) |b, i| out[i] = .{ .set = b.set, .binding = b.binding, .msl_slot = b.reg };
    return out;
}

/// Compile GLSL to SPIR-V, surfacing every collected Diagnostic to stderr
/// in glslang-style format before exiting on failure. Used by all CLI
/// commands that take GLSL source as input. Also applies any
/// `cli_spec_overrides` populated from `--spec-const ID=VALUE` flags.
fn compileWithDiagsOrExit(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    opts: zioshade.CompileOptions,
) []const u32 {
    var diags = std.ArrayListUnmanaged(zioshade.diagnostic.Diagnostic).empty;
    defer {
        for (diags.items) |d| alloc.free(d.message);
        diags.deinit(alloc);
    }
    // The CLI compiles complete shaders, so a missing `main` is a hard error
    // rather than an OpEntryPoint-less (invalid) module emitted at exit 0.
    var cli_opts = opts;
    cli_opts.require_entry_point = true;
    const spv = zioshade.compileToSPIRVWithDiagnostics(alloc, source, cli_opts, &diags) catch |e| {
        // When we have structured diagnostics they already carry the file, line,
        // column, and message, so printing them is the whole story. Only fall
        // back to the bare error-name line when nothing more specific exists,
        // instead of always dumping a redundant `error: <Name> (<detail>)`.
        if (diags.items.len > 0) {
            for (diags.items) |*d| {
                d.path = cli_input_path;
                printDiagnostic(d.*);
            }
            std.process.exit(1);
        }
        compileErr(e);
    };
    if (cli_spec_overrides.len == 0) return spv;
    // Apply overrides (mutates the SPIR-V in a new buffer; frees the
    // intermediate). On allocation failure we fall back to the unmodified
    // SPIR-V — better than crashing the CLI.
    const out = alloc.alloc(u32, spv.len) catch return spv;
    @memcpy(out, spv);
    alloc.free(spv);
    zioshade.applySpecOverrides(out, cli_spec_overrides);
    return out;
}

fn crossErr(err: anyerror) noreturn {
    // MSL/GLSL: component packing (`layout(location=N, component=M)`) is not yet
    // supported. Metal's [[user(locnN)]] has no component offset (spirv-cross widens
    // to vec4 + swizzle); desktop GLSL has no component qualifier. Surface the
    // actionable workaround. Shared by the MSL and GLSL backends.
    if (err == error.UnsupportedComponentPacking) {
        std.debug.print(
            "error: cross-compilation failed: {s}: component packing (`layout(location=N, component=M)`) is not yet supported. Workaround: pack the components into a single varying manually.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // GLSL: subpassInput (Vulkan input attachments) have no desktop-GLSL form.
    if (err == error.UnsupportedSubpassInput) {
        std.debug.print(
            "error: cross-compilation failed: {s}: subpassInput / input attachments are Vulkan-only and have no desktop-GLSL equivalent (subpassInput/subpassLoad require Vulkan GLSL semantics). Workaround: target Vulkan GLSL, or replace the input attachment with a regular texture sample.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // GLSL: multisample image/sampler types (sampler2DMS / image2DMS) are not lowered.
    if (err == error.UnsupportedMultisampleImage) {
        std.debug.print(
            "error: cross-compilation failed: {s}: multisample sampler/image types (sampler2DMS, image2DMS, textureSamples/imageSamples) are not yet lowered by the GLSL backend. Workaround: emit the MS types and queries manually, or avoid multisample resources.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // GLSL: gl_DrawID is a vertex-stage-only builtin; no fragment GLSL declares it.
    if (err == error.UnsupportedFragmentDrawId) {
        std.debug.print(
            "error: cross-compilation failed: {s}: gl_DrawID is a vertex-stage-only builtin and is not declared in fragment GLSL under any version. Workaround: move the gl_DrawID read to the vertex stage and pass it down as a varying.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // GLSL: barycentric coords need pervertexEXT input arrays (not yet lowered).
    if (err == error.UnsupportedBarycentric) {
        std.debug.print(
            "error: cross-compilation failed: {s}: barycentric coordinates (gl_BaryCoord*) require pervertexEXT per-vertex input arrays, which the GLSL backend does not yet lower. Workaround: emit the per-vertex arrays and the GL_EXT_fragment_shader_barycentric (or GL_NV_fragment_shader_barycentric) extension manually.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // GLSL: Vulkan separate sampler+texture are not combined into a sampler2D.
    if (err == error.UnsupportedSeparateSamplers) {
        std.debug.print(
            "error: cross-compilation failed: {s}: Vulkan separate samplers (`uniform sampler` + `uniform texture2D` combined via `sampler2D(tex, samp)`) are not yet supported. Workaround: use a single combined `uniform sampler2D`, or combine the separate resources manually.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // MSL: gl_SamplePosition is a fragment input builtin with no Metal [[attribute]]
    // (spirv-cross computes it from sample positions). Surface the workaround.
    if (err == error.UnsupportedSamplePosition) {
        std.debug.print(
            "error: cross-compilation failed: {s}: gl_SamplePosition is not yet supported in the MSL backend (no direct Metal attribute). Workaround: compute the sample position from [[sample_id]] via get_sample_position(), or avoid gl_SamplePosition.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // MSL/GLSL/HLSL: a do-while with a short-circuit && / || back-edge condition is now
    // lowered end-to-end (single-level). This fires only for shapes the lowering can't
    // rebuild inline: a back-edge phi with a non-inlineable operand, or a multi-level
    // nested OpSelectionMerge in the continue (#77).
    if (err == error.UnsupportedDoWhileCompoundCond) {
        std.debug.print(
            "error: cross-compilation failed: {s}: a do-while loop with a short-circuit && / || back-edge condition whose phi shape the MSL/GLSL/HLSL backends can't rebuild inline (e.g. a multi-level nested OpSelectionMerge in the continue, or a non-inlineable operand). The common single-level form is supported. Workaround: hoist the compound condition into a single bool computed before the loop, or rewrite the loop as a while with an explicit break. (The WGSL backend handles this correctly.)\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // MSL: multisampled Vulkan input attachments (subpassInputMS) need texture2d_ms +
    // a per-sample read (read(coord, sample)); this backend defers MS texture-type
    // modeling, so refuse rather than emit a non-MS read that silently samples the
    // wrong pixel/sample.
    if (err == error.UnsupportedMultisampledSubpassInput) {
        std.debug.print(
            "error: cross-compilation failed: {s}: multisampled Vulkan input attachments (subpassInputMS) are not yet lowered by the MSL backend (need texture2d_ms + per-sample read). Workaround: use a non-MS input attachment, or lower the MS subpass read manually.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // HLSL/etc.: an array length that can't be resolved to a concrete size for a
    // backend without specialization constants (e.g. an OpSpecConstantOp shape this
    // backend can't evaluate). Refuse rather than emit a wrong/garbage dimension.
    if (err == error.UnsupportedSpecConstantArraySize) {
        std.debug.print(
            "error: cross-compilation failed: {s}: an array length could not be resolved to a concrete size for this backend (e.g. an OpSpecConstantOp specialization-constant expression it can't evaluate). Workaround: use a literal or plain spec-constant size.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // HLSL: a vertex output interface block whose member names collide with
    // standalone outputs (or another block) can't flatten into VS_OUTPUT without
    // duplicate fields, and the write-routing can't prefix member names. Refuse
    // rather than emit a confusing undeclared-identifier INVALID. (Full lowering
    // via member-name prefixing / block reconstruction is a follow-up.)
    if (err == error.UnsupportedCollidingOutputBlock) {
        std.debug.print(
            "error: cross-compilation failed: {s}: a vertex output interface block has member names that collide with standalone outputs (or another block); this backend can't flatten it without duplicate VS_OUTPUT fields. Workaround: rename the colliding members, or drop the standalone outputs / block.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // WGSL records an actionable detail for some honest errors (errors carry no
    // payload) — surface it so the message is more than just the error name.
    if (err == error.UnsupportedExtInst or err == error.UnsupportedEarlyReturn) {
        if (zioshade.wgslLastErrorDetail()) |detail| {
            std.debug.print("error: cross-compilation failed: {s}: {s}\n", .{ @errorName(err), detail });
            std.process.exit(1);
        }
    }
    // HLSL: push constants are accessed by instance name in the body but the cbuffer
    // model flattens members to globals, so a named-instance push constant can't be
    // emitted faithfully yet.
    if (err == error.UnsupportedPushConstant) {
        std.debug.print(
            "error: cross-compilation failed: {s}: push_constant blocks are not yet supported in the HLSL backend (named-instance uniform-buffer access is not modeled). Workaround: use a regular UBO (layout(set, binding) uniform), or move the data into a cbuffer manually.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // HLSL: a struct used as a stage input (e.g. `in MyStruct { ... } v;`) is not
    // flattened into per-member signature params, so it can't be emitted faithfully yet.
    if (err == error.UnsupportedStructStageInput) {
        std.debug.print(
            "error: cross-compilation failed: {s}: struct stage inputs (a struct used directly as an `in` varying) are not yet flattened by the HLSL backend. Workaround: flatten the struct into individual `in` varyings (one location each).\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    if (err == error.UnsupportedStructStageOutput) {
        std.debug.print(
            "error: cross-compilation failed: {s}: struct stage outputs (a struct used directly as a vertex `out` varying) are not yet flattened into the VS_OUTPUT by the HLSL backend. Workaround: flatten the struct into individual `out` varyings (one location each).\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // HLSL: a stage-input varying referenced inside a non-main (helper) function is
    // undeclared there (varyings are passed as main() params). Honest-error until
    // varying-threading into helper signatures lands (MSL #476 analog).
    if (err == error.UnsupportedVaryingInHelper) {
        std.debug.print(
            "error: cross-compilation failed: {s}: a stage-input varying is read directly inside a helper (non-main) function, which the HLSL backend does not yet support (varyings are scoped to main). Workaround: pass the varying into the helper as a parameter, or move its use into main.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // HLSL: an array stage input (e.g. gl_ClipDistance[N]) is emitted scalar-then-indexed.
    if (err == error.UnsupportedArrayStageInput) {
        std.debug.print(
            "error: cross-compilation failed: {s}: array stage inputs (an `in` varying of array type, e.g. gl_ClipDistance) are not yet lowered by the HLSL backend. Workaround: avoid array stage inputs, or pass the elements as individual varyings.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // HLSL: gl_ClipDistance / gl_CullDistance as a stage input (array builtin).
    if (err == error.UnsupportedBuiltinStageInput) {
        std.debug.print(
            "error: cross-compilation failed: {s}: gl_ClipDistance / gl_CullDistance as a stage input are not yet lowered by the HLSL backend (array builtin emitted scalar-then-indexed). Workaround: avoid clip/cull distance in this stage, or pass the needed element as a scalar varying.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // HLSL: a Vulkan separate sampler (standalone `uniform sampler`) is never declared.
    if (err == error.UnsupportedSeparateSampler) {
        std.debug.print(
            "error: cross-compilation failed: {s}: Vulkan separate samplers (a standalone `uniform sampler` combined with `uniform texture2D` via sampler2D(tex, samp)) are not yet supported by the HLSL backend. Workaround: use a single combined `uniform sampler2D`.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // MSL: a nested-loop cross-scope phi (an outer loop's carry reads a value from
    // a nested loop's merge) only arises on spirv-opt -O optimized SPIR-V and
    // exceeds zioshade's per-region phi-materialization. Honest-error rather than
    // emit silent-wrong MSL.
    if (err == error.UnsupportedNestedLoopPhi) {
        std.debug.print(
            "error: cross-compilation failed: {s}: this shader has a nested-loop control-flow pattern (a loop value depends on an inner loop's exit) that the MSL backend cannot yet structure correctly on optimized SPIR-V. Workaround: feed UNOPTIMIZED SPIR-V (drop `spirv-opt -O`) — zioshade is provably correct on the unoptimized path.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // MSL: an OpPhi whose predecessors carry DIFFERENT values, which none of the
    // structured merge handlers claimed. The only name available is one incoming
    // value's, which would be that predecessor's value on every path.
    if (err == error.UnsupportedPhiAlias) {
        std.debug.print(
            "error: cross-compilation failed: {s}: this shader has a control-flow merge whose value differs by predecessor in a shape the MSL backend cannot yet materialize. Emitting it would silently use one branch's value on every path, so zioshade refuses instead. Workaround: feed UNOPTIMIZED SPIR-V (drop `spirv-opt -O`), which keeps the value in a variable rather than a phi.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // A loop whose top-test block is really the head of a short-circuit chain
    // (`while (a && b)`). Emitting it would drop the second operand and leave the
    // chain's merge phi unassigned -- silently, since the result still compiles.
    if (err == error.UnsupportedShortCircuitLoopCond) {
        std.debug.print(
            "error: cross-compilation failed: {s}: this shader has a loop whose condition is a short-circuit chain (`while (a && b)`) in a form the backend cannot yet structure. Emitting it would silently drop the second operand, so zioshade refuses instead. Workaround: rewrite the loop condition as a single expression, or hoist the second test into an `if (...) break;` in the body.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // MSL/WGSL: a NON-square row_major buffer/SSBO matrix member (mat2x4, mat3x4,
    // mat2x3 arrays, ...) has no sound spelling in either language: MSL and WGSL
    // matrices are column-major in memory with no layout qualifier, so the
    // transposed declaration would need MatrixStride-dependent widening plus
    // per-access swizzle surgery (spirv-cross's approach; naga refuses the same
    // shape). SQUARE row_major matrices ARE supported (reads are transposed).
    // Name the shape so the refusal is actionable instead of a bare error name.
    if (err == error.UnsupportedRowMajorMatrix) {
        std.debug.print(
            "error: cross-compilation failed: {s}: a NON-square row_major matrix member (e.g. mat2x4/mat3x4/mat2x3) in a uniform/storage block has no sound MSL/WGSL lowering (both store matrices column-major with no row_major qualifier). Workaround: declare the matrix column_major (the default), use a square row_major matrix (supported, reads are transposed), or transpose it in the shader before the buffer layout is chosen.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // MSL/WGSL: OpCompositeExtract reaching a row_major matrix member inside a
    // composite value whose byte provenance cannot be proven (a struct returned
    // by a function call, a select, or a phi joining loaded and constructed
    // values). Raw buffer bytes need transpose(...); register-assembled bytes
    // must NOT be transposed -- guessing either way would silently miscompile,
    // so the backend refuses.
    if (err == error.UnsupportedRowMajorExtractProvenance) {
        std.debug.print(
            "error: cross-compilation failed: {s}: a row_major matrix is extracted from a composite value whose byte provenance cannot be proven (a struct returned by a function call, a select, or a phi mixing buffer-loaded and constructed values). Workaround: extract the row_major matrix in the function that loads it and return/pass the matrix itself, or copy through a local variable before extracting.\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    }
    // WGSL honest-errors (UnsupportedOp / UnsupportedExtInst) carry a precise reason in
    // spirv_to_wgsl.last_error_detail (which construct is unrepresentable / which GLSL.std.450
    // instruction has no mapping). Surface it so the refusal is actionable instead of a bare
    // error name. Gated to WGSL errors so a stale detail can't leak into a non-WGSL error.
    const wgsl_detail: ?[]const u8 = if (err == error.UnsupportedOp or err == error.UnsupportedExtInst) zioshade.wgslLastErrorDetail() else null;
    if (wgsl_detail) |d| {
        std.debug.print("error: cross-compilation failed: {s}: {s}\n", .{ @errorName(err), d });
    } else {
        std.debug.print("error: cross-compilation failed: {s}\n", .{@errorName(err)});
    }
    std.process.exit(1);
}
