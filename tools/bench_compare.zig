//! Head-to-head benchmark: glslpp (in-process Zig library) vs glslang +
//! spirv-cross (invoked as subprocess CLIs). Emits a markdown table.
//!
//! This is a *workflow* comparison: most projects integrate the C++ pipeline
//! by spawning the CLI tools per shader. glslpp avoids that by being an
//! in-process library. A library-vs-library comparison would require linking
//! libglslang.a + libspirv-cross.a, which the Zig build does not do.
//!
//! Build with:  zig build bench-compare
//! Override toolchain paths via env vars:
//!   GLSLPP_BENCH_GLSLANG   — path to glslangValidator(.exe)
//!   GLSLPP_BENCH_SPIRVX    — path to spirv-cross(.exe)

const std = @import("std");
const glslpp = @import("glslpp");

const Shader = struct {
    name: []const u8,
    source: [:0]const u8,
    stage: glslpp.Stage = .fragment,
};

const SHADERS = [_]Shader{
    .{
        .name = "trivial_frag",
        .source =
        \\#version 430
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(1.0, 0.5, 0.25, 1.0); }
        ,
    },
    .{
        .name = "typical_frag",
        .source =
        \\#version 430
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\layout(binding = 0) uniform Globals {
        \\    float u_time;
        \\    vec2  u_resolution;
        \\} g;
        \\void main() {
        \\    vec2 p = (uv - 0.5) * 2.0;
        \\    float d = length(p);
        \\    vec3 col = 0.5 + 0.5 * cos(g.u_time + d + vec3(0, 2, 4));
        \\    fragColor = vec4(col, 1.0);
        \\}
        ,
    },
    .{
        .name = "raymarch",
        .source =
        \\#version 430
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\layout(binding = 0) uniform U { float t; vec2 res; } u;
        \\float sdf(vec3 p) {
        \\    vec3 q = mod(p, 2.0) - 1.0;
        \\    return length(q) - 0.3 + 0.1 * sin(u.t + p.x);
        \\}
        \\void main() {
        \\    vec2 p = (uv - 0.5) * 2.0;
        \\    vec3 ro = vec3(0.0, 0.0, -3.0);
        \\    vec3 rd = normalize(vec3(p, 1.0));
        \\    float t = 0.0;
        \\    for (int i = 0; i < 48; i++) {
        \\        float d = sdf(ro + rd * t);
        \\        if (d < 0.001) break;
        \\        t += d;
        \\        if (t > 20.0) break;
        \\    }
        \\    vec3 col = vec3(1.0 - t * 0.05);
        \\    fragColor = vec4(col, 1.0);
        \\}
        ,
    },
    .{
        .name = "simple_compute",
        .stage = .compute,
        .source =
        \\#version 430
        \\layout(local_size_x = 16, local_size_y = 16) in;
        \\layout(std430, binding = 0) buffer Out { float data[]; } out_buf;
        \\layout(binding = 1) uniform Params { float scale; } p;
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.y * 256 + gl_GlobalInvocationID.x;
        \\    out_buf.data[idx] = float(idx) * p.scale;
        \\}
        ,
    },
};

const ITERS: u64 = 50;
const WARMUP: u64 = 3;

const Stats = struct {
    min_us: u64 = std.math.maxInt(u64),
    avg_us: u64 = 0,
    max_us: u64 = 0,
    bytes_out: usize = 0,
};

fn findTool(env_name: []const u8, default_name: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(alloc, env_name)) |v| {
        return v;
    } else |_| {}
    return alloc.dupe(u8, default_name);
}

fn benchGlslpp(alloc: std.mem.Allocator, shader: Shader) !Stats {
    var stats: Stats = .{};
    var w: u64 = 0;
    while (w < WARMUP) : (w += 1) {
        const spirv = glslpp.compileToSPIRV(alloc, shader.source, .{ .stage = shader.stage }) catch return error.WarmupFailed;
        alloc.free(spirv);
    }
    var total_ns: u128 = 0;
    var iter: u64 = 0;
    while (iter < ITERS) : (iter += 1) {
        const start = std.time.Instant.now() catch continue;
        const spirv = try glslpp.compileToSPIRV(alloc, shader.source, .{ .stage = shader.stage });
        defer alloc.free(spirv);
        const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .binding_shift = -1, .shader_model = 60 });
        defer alloc.free(hlsl);
        const end = std.time.Instant.now() catch continue;
        const dur_ns: u64 = end.since(start);
        total_ns += dur_ns;
        const dur_us = dur_ns / 1000;
        stats.min_us = @min(stats.min_us, dur_us);
        stats.max_us = @max(stats.max_us, dur_us);
        stats.bytes_out = hlsl.len;
    }
    stats.avg_us = @intCast((total_ns / ITERS) / 1000);
    return stats;
}

fn benchReference(
    alloc: std.mem.Allocator,
    shader: Shader,
    glslang_path: []const u8,
    spirvx_path: []const u8,
    tmpdir: []const u8,
) !?Stats {
    const stage_ext: []const u8 = switch (shader.stage) {
        .fragment => "frag",
        .vertex => "vert",
        .compute => "comp",
        else => return null,
    };
    const sep = std.fs.path.sep_str;
    const src_path = try std.fmt.allocPrint(alloc, "{s}{s}{s}.{s}", .{ tmpdir, sep, shader.name, stage_ext });
    defer alloc.free(src_path);
    const spv_path = try std.fmt.allocPrint(alloc, "{s}{s}{s}.spv", .{ tmpdir, sep, shader.name });
    defer alloc.free(spv_path);

    {
        const f = try std.fs.createFileAbsolute(src_path, .{});
        defer f.close();
        try f.writeAll(std.mem.sliceTo(shader.source, 0));
    }

    var stats: Stats = .{};
    var w: u64 = 0;
    while (w < WARMUP) : (w += 1) {
        const r = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ glslang_path, "-V", src_path, "-o", spv_path },
        }) catch return error.WarmupFailed;
        defer alloc.free(r.stdout);
        defer alloc.free(r.stderr);
        if (r.term != .Exited or r.term.Exited != 0) return null;
    }

    var total_ns: u128 = 0;
    var iter: u64 = 0;
    while (iter < ITERS) : (iter += 1) {
        const start = std.time.Instant.now() catch continue;

        const r1 = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ glslang_path, "-V", src_path, "-o", spv_path },
        });
        alloc.free(r1.stdout);
        alloc.free(r1.stderr);
        if (r1.term != .Exited or r1.term.Exited != 0) return null;

        const r2 = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ spirvx_path, "--hlsl", "--shader-model", "60", spv_path },
        });
        defer alloc.free(r2.stdout);
        defer alloc.free(r2.stderr);
        if (r2.term != .Exited or r2.term.Exited != 0) return null;

        const end = std.time.Instant.now() catch continue;
        const dur_ns: u64 = end.since(start);
        total_ns += dur_ns;
        const dur_us = dur_ns / 1000;
        stats.min_us = @min(stats.min_us, dur_us);
        stats.max_us = @max(stats.max_us, dur_us);
        stats.bytes_out = r2.stdout.len;
    }
    stats.avg_us = @intCast((total_ns / ITERS) / 1000);
    return stats;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const glslang = try findTool("GLSLPP_BENCH_GLSLANG", "glslangValidator", alloc);
    defer alloc.free(glslang);
    const spirvx = try findTool("GLSLPP_BENCH_SPIRVX", "spirv-cross", alloc);
    defer alloc.free(spirvx);

    // Temp dir for subprocess inputs.
    var tmp_arena = std.heap.ArenaAllocator.init(alloc);
    defer tmp_arena.deinit();
    const tmp_alloc = tmp_arena.allocator();
    const sysroot_tmp = std.process.getEnvVarOwned(tmp_alloc, "TEMP") catch
        std.process.getEnvVarOwned(tmp_alloc, "TMPDIR") catch
        try tmp_alloc.dupe(u8, "/tmp");
    const tmpdir = try std.fmt.allocPrint(tmp_alloc, "{s}{s}glslpp-bench-{d}", .{ sysroot_tmp, std.fs.path.sep_str, std.time.timestamp() });
    std.fs.makeDirAbsolute(tmpdir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Use std.debug.print for output — Zig 0.15.2's std.io is being restructured.
    const out = struct {
        fn print(comptime fmt: []const u8, args: anytype) !void {
            std.debug.print(fmt, args);
        }
    };

    try out.print("# glslpp vs glslang+spirv-cross benchmark\n\n", .{});
    try out.print("- Iterations per shader: {d} (after {d} warmup)\n", .{ ITERS, WARMUP });
    try out.print("- glslpp: in-process Zig library call (GLSL → SPIR-V → HLSL SM 6.0)\n", .{});
    try out.print("- reference: `{s}` + `{s}` invoked as subprocess CLIs (same pipeline)\n\n", .{ glslang, spirvx });
    try out.print("| Shader | glslpp avg | glslpp min | reference avg | reference min | speedup (avg) | HLSL bytes glslpp / ref |\n", .{});
    try out.print("|---|---:|---:|---:|---:|---:|---:|\n", .{});

    for (SHADERS) |sh| {
        const g = benchGlslpp(alloc, sh) catch |err| {
            try out.print("| {s} | ERR: {s} | | | | | |\n", .{ sh.name, @errorName(err) });
            continue;
        };
        const r_opt = benchReference(alloc, sh, glslang, spirvx, tmpdir) catch |err| {
            try out.print("| {s} | {d} us | {d} us | ERR: {s} | | | |\n", .{ sh.name, g.avg_us, g.min_us, @errorName(err) });
            continue;
        };
        if (r_opt) |r| {
            const speedup_x10 = if (g.avg_us > 0) @divFloor(r.avg_us * 10, g.avg_us) else 0;
            try out.print(
                "| {s} | {d} us | {d} us | {d} us | {d} us | {d}.{d}× | {d} / {d} |\n",
                .{ sh.name, g.avg_us, g.min_us, r.avg_us, r.min_us, speedup_x10 / 10, speedup_x10 % 10, g.bytes_out, r.bytes_out },
            );
        } else {
            try out.print("| {s} | {d} us | {d} us | (reference failed) | | | |\n", .{ sh.name, g.avg_us, g.min_us });
        }
    }

    try out.print("\n", .{});
    try out.print("> **Caveat:** this benchmark compares **in-process glslpp** to **subprocess glslang+spirv-cross**. ", .{});
    try out.print("Most projects integrate the C++ pipeline by spawning these CLI tools, so this matches real-world workflow cost. ", .{});
    try out.print("Most of the gap is process-spawn overhead; a true library-vs-library comparison ", .{});
    try out.print("(linking libglslang.a + libspirv-cross.a) is not yet published.\n", .{});
}
