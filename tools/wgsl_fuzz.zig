const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const iterations = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 1000;
    const seed = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 42;

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var ok: u32 = 0;
    var crash: u32 = 0;
    var compile_fail: u32 = 0;
    var wgsl_fail: u32 = 0;

    const funcs = [_][]const u8{ "sin", "cos", "tan", "abs", "sign", "floor", "ceil", "fract", "sqrt", "pow", "exp", "log", "exp2", "log2", "radians", "degrees", "min", "max", "clamp", "mix", "step", "smoothstep", "length", "distance", "normalize", "dot", "cross", "reflect", "refract" };

    var shader_buf: [4096]u8 = undefined;

    for (0..iterations) |_| {
        var fbs = std.io.fixedBufferStream(&shader_buf);
        const w = fbs.writer();

        // Generate a random fragment shader
        w.writeAll("#version 450\n") catch continue;
        w.writeAll("uniform vec2 u_resolution;\n") catch continue;
        w.writeAll("out vec4 fragColor;\n\n") catch continue;

        // Maybe add a helper function
        if (rng.boolean()) {
            w.writeAll("float helper(float x) {\n") catch continue;
            const n_stmts = rng.intRangeAtMost(usize, 1, 3);
            for (0..n_stmts) |_| {
                const f = funcs[rng.intRangeAtMost(usize, 0, funcs.len - 1)];
                w.print("    x = {s}(x);\n", .{f}) catch continue;
            }
            w.writeAll("    return x;\n}\n\n") catch continue;
        }

        w.writeAll("void main() {\n") catch continue;

        // Generate random statements
        const n_stmts = rng.intRangeAtMost(usize, 2, 8);
        for (0..n_stmts) |_| {
            const stmt_type = rng.intRangeAtMost(usize, 0, 5);
            switch (stmt_type) {
                0 => {
                    // Builtin function on constant
                    const f = funcs[rng.intRangeAtMost(usize, 0, funcs.len - 1)];
                    w.print("    float a = {s}({d:.3});\n", .{ f, rng.float(f32) * 3.14 }) catch continue;
                },
                1 => {
                    // Vector construction
                    w.print("    vec3 v = vec3({d:.1}, {d:.1}, {d:.1});\n", .{ rng.float(f32), rng.float(f32), rng.float(f32) }) catch continue;
                },
                2 => {
                    // Gl_FragCoord usage
                    w.writeAll("    vec2 uv = gl_FragCoord.xy / u_resolution;\n") catch continue;
                },
                3 => {
                    // Mix/clamp
                    w.print("    float b = clamp({d:.2}, 0.0, 1.0);\n", .{rng.float(f32)}) catch continue;
                },
                4 => {
                    // Type conversion
                    w.print("    int n = int({d:.0}); float f = float(n);\n", .{rng.float(f32) * 10.0}) catch continue;
                },
                else => {
                    // Simple constant
                    w.print("    float c = {d:.3};\n", .{rng.float(f32) * 10.0}) catch continue;
                },
            }
        }

        if (rng.boolean()) {
            w.writeAll("    fragColor = vec4(1.0, 0.0, 0.0, 1.0);\n") catch continue;
        } else {
            w.writeAll("    fragColor = vec4(0.5, 0.5, 0.5, 1.0);\n") catch continue;
        }
        w.writeAll("}\n") catch continue;

        const source = fbs.getWritten();
        const sourceZ = try alloc.dupeZ(u8, source);
        defer alloc.free(sourceZ);

        // Try to compile to SPIR-V
        const spv_result = glslpp.compileToSPIRV(alloc, sourceZ, .{ .stage = .fragment }) catch {
            compile_fail += 1;
            continue;
        };
        defer alloc.free(spv_result);

        // Try to convert to WGSL
        const wgsl_result = glslpp.spirvToWGSL(alloc, spv_result, .{}) catch |err| {
            crash += 1;
            if (crash <= 20) {
                std.debug.print("  WGSL CRASH #{d}: {} — source:\n{s}\n\n", .{ crash, err, source });
            }
            continue;
        };
        defer alloc.free(wgsl_result);

        if (wgsl_result.len == 0) {
            wgsl_fail += 1;
            continue;
        }

        ok += 1;
    }

    std.debug.print("\n=== WGSL Fuzz Results ===\n", .{});
    std.debug.print("Iterations:  {d}\n", .{iterations});
    std.debug.print("OK:          {d}\n", .{ok});
    std.debug.print("Crash:       {d}\n", .{crash});
    std.debug.print("WGSL empty:  {d}\n", .{wgsl_fail});
    std.debug.print("Compile fail: {d}\n", .{compile_fail});
}
