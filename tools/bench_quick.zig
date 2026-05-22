const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const shaders = [_]struct { name: []const u8, source: [:0]const u8 }{
        .{
            .name = "simple_frag",
            .source =
            \\#version 430
            \\layout(location = 0) out vec4 FragColor;
            \\void main() {
            \\    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
            \\    FragColor = vec4(uv.x, uv.y, 0.0, 1.0);
            \\}
            ,
        },
        .{
            .name = "noise_func",
            .source =
            \\#version 430
            \\layout(location = 0) out vec4 FragColor;
            \\float hash(vec2 p) {
            \\    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            \\}
            \\float noise(vec2 p) {
            \\    vec2 i = floor(p);
            \\    vec2 f = fract(p);
            \\    float a = hash(i);
            \\    float b = hash(i + vec2(1.0, 0.0));
            \\    float c = hash(i + vec2(0.0, 1.0));
            \\    float d = hash(i + vec2(1.0, 1.0));
            \\    vec2 u = f * f * (3.0 - 2.0 * f);
            \\    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
            \\}
            \\void main() {
            \\    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
            \\    float n = noise(uv * 8.0);
            \\    FragColor = vec4(n, n, n, 1.0);
            \\}
            ,
        },
        .{
            .name = "struct_loop",
            .source =
            \\#version 430
            \\layout(location = 0) out vec4 FragColor;
            \\struct Light { vec3 pos; vec3 color; float intensity; };
            \\Light lights[4];
            \\vec3 shade(Light l, vec3 p, vec3 n) {
            \\    vec3 d = l.pos - p;
            \\    float dist = length(d);
            \\    return l.color * l.intensity * max(dot(n, normalize(d)), 0.0) / (dist * dist);
            \\}
            \\void main() {
            \\    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
            \\    vec3 p = vec3(uv, 1.0);
            \\    vec3 n = normalize(vec3(0.0, 0.0, 1.0));
            \\    vec3 col = vec3(0.0);
            \\    for (int i = 0; i < 4; i++) {
            \\        lights[i].pos = vec3(float(i) * 2.0, float(i) * 3.0, 5.0);
            \\        lights[i].color = vec3(1.0, 0.5, 0.2);
            \\        lights[i].intensity = 10.0;
            \\        col += shade(lights[i], p, n);
            \\    }
            \\    FragColor = vec4(col, 1.0);
            \\}
            ,
        },
    };

    const warmup = 50;
    const iterations = 500;

    // Warmup
    for (0..warmup) |_| {
        for (shaders) |s| {
            const spirv = glslpp.compileToSPIRV(alloc, s.source, .{ .stage = .fragment }) catch continue;
            alloc.free(spirv);
        }
    }

    // Compile-only benchmark
    std.debug.print("{s:<16} {s:>12} {s:>12} {s:>12} {s:>8}\n", .{ "Shader", "Avg(µs)", "Min(µs)", "Max(µs)", "Size(w)" });
    std.debug.print("{s}\n", .{"-" ** 64});

    for (shaders) |shader| {
        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var max_ns: u64 = 0;
        var spirv_size: u32 = 0;

        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const spirv = glslpp.compileToSPIRV(alloc, shader.source, .{ .stage = .fragment }) catch continue;
            const end = std.time.nanoTimestamp();
            const elapsed = @as(u64, @intCast(end - start));
            total_ns += elapsed;
            if (elapsed < min_ns) min_ns = elapsed;
            if (elapsed > max_ns) max_ns = elapsed;
            spirv_size = @intCast(spirv.len);
            alloc.free(spirv);
        }

        const avg_us = @divFloor(total_ns, iterations * 1000);
        const min_us = @divFloor(min_ns, 1000);
        const max_us = @divFloor(max_ns, 1000);
        std.debug.print("{s:<16} {d:>12} {d:>12} {d:>12} {d:>8}\n", .{ shader.name, avg_us, min_us, max_us, spirv_size });
    }

    // Full pipeline benchmark (GLSL → SPIR-V → HLSL + GLSL + MSL)
    std.debug.print("\n{s}\n", .{"-" ** 64});
    std.debug.print("Full pipeline: GLSL → SPIR-V → HLSL + GLSL + MSL\n", .{});

    for (shaders) |shader| {
        var total_ns: u64 = 0;

        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const spirv = glslpp.compileToSPIRV(alloc, shader.source, .{ .stage = .fragment }) catch continue;
            const hlsl = glslpp.spirvToHLSL(alloc, spirv, .{}) catch { alloc.free(spirv); continue; };
            const glsl_out = glslpp.spirvToGLSL(alloc, spirv, .{}) catch { alloc.free(spirv); alloc.free(hlsl); continue; };
            const msl = glslpp.spirvToMSL(alloc, spirv, .{}) catch { alloc.free(spirv); alloc.free(hlsl); alloc.free(glsl_out); continue; };
            const end = std.time.nanoTimestamp();
            total_ns += @as(u64, @intCast(end - start));
            alloc.free(spirv);
            alloc.free(hlsl);
            alloc.free(glsl_out);
            alloc.free(msl);
        }

        const avg_us = @divFloor(total_ns, iterations * 1000);
        std.debug.print("  {s:<16} {d} µs (all 3 backends)\n", .{ shader.name, avg_us });
    }

    // Cross-compile only benchmark
    std.debug.print("\n{s}\n", .{"-" ** 64});
    std.debug.print("Cross-compile only: SPIR-V → backend (pre-compiled SPIR-V)\n", .{});

    const pre_spv = glslpp.compileToSPIRV(alloc, shaders[0].source, .{ .stage = .fragment }) catch unreachable;

    var cross_ns: u64 = 0;
    const cross_iters = 2000;
    for (0..cross_iters) |_| {
        const start = std.time.nanoTimestamp();
        const hlsl = glslpp.spirvToHLSL(alloc, pre_spv, .{}) catch continue;
        const end = std.time.nanoTimestamp();
        cross_ns += @as(u64, @intCast(end - start));
        alloc.free(hlsl);
    }
    std.debug.print("  HLSL: {d} µs avg ({d} iterations)\n", .{ @divFloor(cross_ns, cross_iters * 1000), cross_iters });

    var cross_glsl_ns: u64 = 0;
    for (0..cross_iters) |_| {
        const start = std.time.nanoTimestamp();
        const glsl_out = glslpp.spirvToGLSL(alloc, pre_spv, .{}) catch continue;
        const end = std.time.nanoTimestamp();
        cross_glsl_ns += @as(u64, @intCast(end - start));
        alloc.free(glsl_out);
    }
    std.debug.print("  GLSL: {d} µs avg ({d} iterations)\n", .{ @divFloor(cross_glsl_ns, cross_iters * 1000), cross_iters });

    var cross_msl_ns: u64 = 0;
    for (0..cross_iters) |_| {
        const start = std.time.nanoTimestamp();
        const msl = glslpp.spirvToMSL(alloc, pre_spv, .{}) catch continue;
        const end = std.time.nanoTimestamp();
        cross_msl_ns += @as(u64, @intCast(end - start));
        alloc.free(msl);
    }
    std.debug.print("  MSL:  {d} µs avg ({d} iterations)\n", .{ @divFloor(cross_msl_ns, cross_iters * 1000), cross_iters });

    alloc.free(pre_spv);
}
