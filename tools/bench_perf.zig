const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .never_unmap = true, .retain_metadata = false }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const test_shaders = [_]struct { name: []const u8, source: [:0]const u8 }{
        .{
            .name = "simple",
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
            .name = "for_loop",
            .source =
            \\#version 430
            \\layout(location = 0) out vec4 FragColor;
            \\void main() {
            \\    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
            \\    float sum = 0.0;
            \\    for (int i = 0; i < 8; i++) {
            \\        sum += sin(uv.x * 3.14159 * float(i + 1)) * 0.125;
            \\    }
            \\    FragColor = vec4(sum, sum * 0.5, 1.0 - sum, 1.0);
            \\}
            ,
        },
        .{
            .name = "func_calls",
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
            .name = "nested_loop",
            .source =
            \\#version 430
            \\layout(location = 0) out vec4 FragColor;
            \\void main() {
            \\    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
            \\    float v = 0.0;
            \\    for (int i = 0; i < 4; i++) {
            \\        for (int j = 0; j < 4; j++) {
            \\            v += sin(uv.x * float(i+1) * 3.14) * cos(uv.y * float(j+1) * 3.14);
            \\        }
            \\    }
            \\    v = fract(v * 0.5 + 0.5);
            \\    FragColor = vec4(v, v * 0.7, v * 0.3, 1.0);
            \\}
            ,
        },
        .{
            .name = "complex",
            .source =
            \\#version 430
            \\layout(location = 0) out vec4 FragColor;
            \\uniform float iTime;
            \\uniform vec2 iResolution;
            \\mat2 rot(float a) { float c=cos(a),s=sin(a); return mat2(c,-s,s,c); }
            \\float map(vec3 p) {
            \\    float d = length(p) - 1.0;
            \\    d += 0.1 * sin(p.x*5.0) * sin(p.y*5.0) * sin(p.z*5.0);
            \\    return d;
            \\}
            \\vec3 calcNormal(vec3 p) {
            \\    vec2 e = vec2(0.001, 0.0);
            \\    return normalize(vec3(
            \\        map(p+e.xyy) - map(p-e.xyy),
            \\        map(p+e.yxy) - map(p-e.yxy),
            \\        map(p+e.yyx) - map(p-e.yyx)
            \\    ));
            \\}
            \\void main() {
            \\    vec2 uv = (gl_FragCoord.xy - 0.5*iResolution) / iResolution.y;
            \\    vec3 ro = vec3(0.0, 0.0, -3.0);
            \\    vec3 rd = normalize(vec3(uv, 1.0));
            \\    float t = 0.0;
            \\    for (int i = 0; i < 64; i++) {
            \\        vec3 p = ro + rd * t;
            \\        float d = map(p);
            \\        if (d < 0.001) break;
            \\        t += d;
            \\    }
            \\    vec3 col = vec3(0.1, 0.1, 0.2);
            \\    if (t < 10.0) {
            \\        vec3 p = ro + rd * t;
            \\        vec3 n = calcNormal(p);
            \\        vec3 light = normalize(vec3(1.0, 2.0, -1.0));
            \\        float diff = max(dot(n, light), 0.0);
            \\        col = vec3(0.8, 0.3, 0.1) * diff + vec3(0.1);
            \\    }
            \\    FragColor = vec4(col, 1.0);
            \\}
            ,
        },
    };

    const iterations = 100;
    const warmup = 10;

    std.debug.print("glslpp Performance Benchmark ({d} iterations per shader)\n", .{iterations});
    std.debug.print("={s}\n", .{"=" ** 60});
    std.debug.print("{s:<16} {s:>12} {s:>12} {s:>12} {s:>10} {s:>10}\n", .{ "Shader", "Avg (µs)", "Min (µs)", "SPIR-V→HLSL", "SPV words", "HLSL bytes" });
    std.debug.print("{s}\n", .{"-" ** 76});

    var total_avg: u64 = 0;

    for (&test_shaders) |*shader| {
        // Warmup
        for (0..warmup) |_| {
            const spirv = glslpp.compileToSPIRV(alloc, shader.source, .{ .stage = .fragment }) catch break;
            defer alloc.free(spirv);
            const hlsl = glslpp.spirvToHLSL(alloc, spirv, .{}) catch break;
            defer alloc.free(hlsl);
        }

        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var spirv_size: usize = 0;
        var hlsl_size: usize = 0;
        var compile_errors: u32 = 0;

        for (0..iterations) |_| {
            const start = std.time.Instant.now() catch continue;
            const spirv = glslpp.compileToSPIRV(alloc, shader.source, .{ .stage = .fragment }) catch {
                compile_errors += 1;
                continue;
            };
            const hlsl = glslpp.spirvToHLSL(alloc, spirv, .{}) catch {
                alloc.free(spirv);
                compile_errors += 1;
                continue;
            };
            const end = std.time.Instant.now() catch {
                alloc.free(spirv);
                alloc.free(hlsl);
                continue;
            };

            const elapsed = end.since(start);
            total_ns += @as(u64, @intCast(elapsed));
            min_ns = @min(min_ns, @as(u64, @intCast(elapsed)));
            spirv_size = spirv.len;
            hlsl_size = hlsl.len;

            alloc.free(spirv);
            alloc.free(hlsl);
        }

        if (compile_errors == iterations) {
            std.debug.print("{s:<16} COMPILE ERROR\n", .{shader.name});
            continue;
        }

        const valid_iters = iterations - compile_errors;
        const avg_ns = @divFloor(total_ns, valid_iters);
        const avg_us = @divFloor(avg_ns, 1000);
        const min_us = @divFloor(min_ns, 1000);
        total_avg += avg_us;

        // Separate measurement for just SPIR-V → HLSL
        var cross_ns: u64 = 0;
        var cross_count: u32 = 0;
        {
            const spirv = glslpp.compileToSPIRV(alloc, shader.source, .{ .stage = .fragment }) catch continue;
            defer alloc.free(spirv);

            for (0..iterations) |_| {
                const start = std.time.Instant.now() catch continue;
                const hlsl = glslpp.spirvToHLSL(alloc, spirv, .{}) catch continue;
                defer alloc.free(hlsl);
                const end = std.time.Instant.now() catch continue;
                cross_ns += @as(u64, @intCast(end.since(start)));
                cross_count += 1;
            }
        }
        const cross_us = if (cross_count > 0) @divFloor(cross_ns, cross_count * 1000) else 0;

        std.debug.print("{s:<16} {d:>12} {d:>12} {d:>12}µs {d:>10} {d:>10}\n", .{
            shader.name, avg_us, min_us, cross_us, spirv_size, hlsl_size,
        });
    }

    std.debug.print("{s}\n", .{"-" ** 76});
    std.debug.print("Total average: {d} µs across {d} shaders\n", .{ total_avg, test_shaders.len });

    // Also benchmark full pipeline (all 3 backends)
    std.debug.print("\nFull pipeline benchmark (GLSL → SPIR-V → HLSL + GLSL + MSL):\n", .{});
    var full_total_ns: u64 = 0;
    var full_count: u32 = 0;

    for (0..iterations) |_| {
        const source = test_shaders[0].source; // Use the simple shader
        const start = std.time.Instant.now() catch continue;
        const spirv = glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment }) catch continue;
        defer alloc.free(spirv);
        const hlsl = glslpp.spirvToHLSL(alloc, spirv, .{}) catch { alloc.free(spirv); continue; };
        defer alloc.free(hlsl);
        const glsl = glslpp.spirvToGLSL(alloc, spirv, .{}) catch { alloc.free(spirv); continue; };
        defer alloc.free(glsl);
        const msl = glslpp.spirvToMSL(alloc, spirv, .{}) catch { alloc.free(spirv); continue; };
        defer alloc.free(msl);
        const end = std.time.Instant.now() catch continue;

        full_total_ns += @as(u64, @intCast(end.since(start)));
        full_count += 1;
    }

    if (full_count > 0) {
        const full_avg_us = @divFloor(full_total_ns, full_count * 1000);
        std.debug.print("  Average: {d} µs per shader (all 3 backends)\n", .{full_avg_us});
    }
}
