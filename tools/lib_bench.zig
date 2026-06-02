// SPDX-License-Identifier: MIT OR Apache-2.0
//! Library-vs-library benchmark: glslpp vs SPIRV-Cross, both linked IN-PROCESS
//! (no subprocess), cross-compiling the SAME SPIR-V to GLSL / HLSL / MSL.
//!
//! This is the honest "lib-vs-lib" comparison — the older `bench` step times
//! glslpp library calls against the `glslangValidator` *subprocess*, which
//! over-states the win (subprocess spawn + I/O dominate). Here both sides are
//! plain in-process function calls on identical input.
//!
//! SPIRV-Cross is consumed via its C API (`spirv_cross_c.h`, linked from the
//! Vulkan SDK's static libs — see build.zig `lib-bench`). Each iteration does a
//! full parse→emit on both sides (what a real consumer pays per shader).
//!
//! Run: `just lib-bench`  (or `zig build lib-bench -- --iters 2000`)
const std = @import("std");
const glslpp = @import("glslpp");

const c = @cImport({
    @cInclude("spirv_cross_c.h");
});

const Backend = enum { glsl, hlsl, msl };

const Shader = struct {
    name: []const u8,
    stage: glslpp.Stage,
    src: [:0]const u8,
};

// A small, representative corpus that BOTH compilers accept. Kept inline so the
// benchmark is self-contained and deterministic.
const corpus = [_]Shader{
    .{ .name = "minimal", .stage = .fragment, .src =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main() { o = vec4(1.0, 0.5, 0.25, 1.0); }
    },
    .{ .name = "ubo+texture", .stage = .fragment, .src =
        \\#version 450
        \\layout(binding=0) uniform U { vec4 tint; float k; } u;
        \\layout(binding=1) uniform sampler2D tex;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main() { o = texture(tex, uv) * u.tint * u.k; }
    },
    .{ .name = "control-flow", .stage = .fragment, .src =
        \\#version 450
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    float s = 0.0;
        \\    for (int i = 0; i < 8; i++) { s += sin(uv.x * float(i)) * cos(uv.y); }
        \\    o = vec4(vec3(s), 1.0);
        \\}
    },
    .{ .name = "math-heavy", .stage = .fragment, .src =
        \\#version 450
        \\layout(location=0) in vec3 p;
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    vec3 q = normalize(p);
        \\    float d = dot(q, vec3(0.577)) ;
        \\    vec3 r = reflect(q, vec3(0.0, 1.0, 0.0));
        \\    o = vec4(mix(q, r, clamp(d, 0.0, 1.0)), length(p));
        \\}
    },
};

fn spvcBackend(b: Backend) c.spvc_backend {
    return switch (b) {
        .glsl => c.SPVC_BACKEND_GLSL,
        .hlsl => c.SPVC_BACKEND_HLSL,
        .msl => c.SPVC_BACKEND_MSL,
    };
}

/// One full SPIRV-Cross parse→emit of `spirv` to `backend`. Returns the output
/// length, or null on any SPIRV-Cross error (so the bench can SKIP it).
fn spvcCompile(spirv: []const u32, backend: Backend) ?usize {
    var ctx: c.spvc_context = null;
    if (c.spvc_context_create(&ctx) != c.SPVC_SUCCESS) return null;
    defer c.spvc_context_destroy(ctx);
    var ir: c.spvc_parsed_ir = null;
    if (c.spvc_context_parse_spirv(ctx, @ptrCast(spirv.ptr), spirv.len, &ir) != c.SPVC_SUCCESS) return null;
    var comp: c.spvc_compiler = null;
    if (c.spvc_context_create_compiler(ctx, spvcBackend(backend), ir, c.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &comp) != c.SPVC_SUCCESS) return null;
    var opts: c.spvc_compiler_options = null;
    if (c.spvc_compiler_create_compiler_options(comp, &opts) != c.SPVC_SUCCESS) return null;
    if (c.spvc_compiler_install_compiler_options(comp, opts) != c.SPVC_SUCCESS) return null;
    var result: [*c]const u8 = null;
    if (c.spvc_compiler_compile(comp, &result) != c.SPVC_SUCCESS) return null;
    if (result == null) return null;
    return std.mem.len(result);
}

/// One full glslpp parse→emit of `spirv` to `backend`. Returns output length,
/// or null on error.
fn glslppCompile(alloc: std.mem.Allocator, spirv: []const u32, backend: Backend) ?usize {
    const out = switch (backend) {
        .glsl => glslpp.spirvToGLSL(alloc, spirv, .{ .version = 450 }),
        .hlsl => glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 60 }),
        .msl => glslpp.spirvToMSL(alloc, spirv, .{}),
    } catch return null;
    defer alloc.free(out);
    return out.len;
}

fn median(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // --iters N (default 1000)
    var iters: usize = 1000;
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--iters")) {
            if (args.next()) |v| iters = std.fmt.parseInt(usize, v, 10) catch iters;
        }
    }

    
    std.debug.print("glslpp vs SPIRV-Cross — in-process, {d} iters/cell (median ns/op)\n\n", .{iters});
    std.debug.print("{s:<14} {s:<7} {s:>12} {s:>12} {s:>8}  bytes\n", .{ "shader", "backend", "glslpp", "spirv-cross", "ratio" });
    std.debug.print("{s}", .{"--------------------------------------------------------------------------\n"});

    const samples = try alloc.alloc(u64, iters);
    defer alloc.free(samples);

    var tot_glslpp: f64 = 0;
    var tot_spvc: f64 = 0;
    var cells: usize = 0;

    for (corpus) |sh| {
        const spirv = glslpp.compileToSPIRV(alloc, sh.src, .{ .stage = sh.stage }) catch {
            std.debug.print("{s:<14} (glslpp could not compile to SPIR-V — skipped)\n", .{sh.name});
            continue;
        };
        defer alloc.free(spirv);

        for ([_]Backend{ .glsl, .hlsl, .msl }) |be| {
            // Correctness gate: both must produce output, else SKIP the cell.
            const g_len = glslppCompile(alloc, spirv, be) orelse {
                std.debug.print("{s:<14} {s:<7}  (glslpp skip)\n", .{ sh.name, @tagName(be) });
                continue;
            };
            const s_len = spvcCompile(spirv, be) orelse {
                std.debug.print("{s:<14} {s:<7}  (spirv-cross skip)\n", .{ sh.name, @tagName(be) });
                continue;
            };

            // Warmup.
            _ = glslppCompile(alloc, spirv, be);
            _ = spvcCompile(spirv, be);

            for (0..iters) |i| {
                var t = std.time.Timer.start() catch unreachable;
                _ = glslppCompile(alloc, spirv, be);
                samples[i] = t.read();
            }
            const g_ns = median(samples);
            for (0..iters) |i| {
                var t = std.time.Timer.start() catch unreachable;
                _ = spvcCompile(spirv, be);
                samples[i] = t.read();
            }
            const s_ns = median(samples);

            const ratio = @as(f64, @floatFromInt(s_ns)) / @as(f64, @floatFromInt(g_ns));
            tot_glslpp += @floatFromInt(g_ns);
            tot_spvc += @floatFromInt(s_ns);
            cells += 1;
            std.debug.print("{s:<14} {s:<7} {d:>12} {d:>12} {d:>7.2}x  {d}/{d}\n", .{ sh.name, @tagName(be), g_ns, s_ns, ratio, g_len, s_len });
        }
    }

    if (cells > 0) {
        std.debug.print("\nAggregate median-of-medians ratio (spirv-cross / glslpp): {d:.2}x over {d} cells\n", .{ tot_spvc / tot_glslpp, cells });
        std.debug.print("{s}", .{"(ratio > 1 means glslpp is faster; both are in-process parse→emit on identical SPIR-V)\n"});
    } else {
        std.debug.print("{s}", .{"\nNo comparable cells — check SPIRV-Cross linkage.\n"});
    }
}
