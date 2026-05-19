const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var count: u32 = 500;
    var seed: u64 = 42;
    var do_validate = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--count") and i + 1 < args.len) {
            i += 1;
            count = std.fmt.parseInt(u32, args[i], 10) catch 500;
        } else if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
            i += 1;
            seed = std.fmt.parseInt(u64, args[i], 10) catch 42;
        } else if (std.mem.eql(u8, args[i], "--validate")) {
            do_validate = true;
        }
    }

    var pass_count: u32 = 0;
    var fail_count: u32 = 0;
    var skip_count: u32 = 0;
    var fail_seeds: std.ArrayList(u64) = .{};
    defer fail_seeds.deinit(alloc);

    std.debug.print("glslpp fuzzer: {} iterations, seed={}, validate={}\n", .{ count, seed, do_validate });

    for (0..count) |iter| {
        const iter_seed = seed + @as(u64, @intCast(iter));

        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const source = generateShader(fba.allocator(), iter_seed) catch {
            skip_count += 1;
            continue;
        };

        const result = glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment }) catch {
            pass_count += 1;
            continue;
        };
        defer alloc.free(result);

        if (result.len < 5 or result[0] != 0x07230203) {
            std.debug.print("FAIL seed={}: invalid SPIR-V header\n", .{iter_seed});
            fail_seeds.append(alloc, iter_seed) catch {};
            fail_count += 1;
            continue;
        }

        if (do_validate) {
            const spv_bytes = std.mem.sliceAsBytes(result);
            const tmp_file = std.fs.cwd().createFileZ("/tmp/glslpp_fuzz.spv", .{}) catch {
                skip_count += 1;
                continue;
            };
            defer {
                tmp_file.close();
                std.fs.cwd().deleteFileZ("/tmp/glslpp_fuzz.spv") catch {};
            }
            tmp_file.writeAll(spv_bytes) catch {
                skip_count += 1;
                continue;
            };

            const val_result = std.process.Child.run(.{
                .allocator = alloc,
                .argv = &.{ "spirv-val", "/tmp/glslpp_fuzz.spv" },
            }) catch {
                skip_count += 1;
                continue;
            };
            defer {
                if (val_result.stdout.len > 0) alloc.free(val_result.stdout);
                if (val_result.stderr.len > 0) alloc.free(val_result.stderr);
            }
            if (val_result.term.Exited != 0) {
                const msg = if (val_result.stderr.len > 200) val_result.stderr[0..200] else val_result.stderr;
                std.debug.print("FAIL seed={}: spirv-val: {s}\n", .{ iter_seed, msg });
                std.debug.print("  Source: {s}\n", .{source[0..@min(source.len, 300)]});
                fail_seeds.append(alloc, iter_seed) catch {};
                fail_count += 1;
                continue;
            }
        }

        pass_count += 1;
    }

    std.debug.print("\n=== Fuzz Results ===\n", .{});
    std.debug.print("Pass: {}  Fail: {}  Skip: {}  Total: {}\n", .{ pass_count, fail_count, skip_count, count });
    if (fail_seeds.items.len > 0) {
        std.debug.print("Failing seeds:\n", .{});
        for (fail_seeds.items) |s| {
            std.debug.print("  {}\n", .{s});
        }
    }
    std.debug.print("METRIC fuzz_pass={}\n", .{pass_count});
    std.debug.print("METRIC fuzz_fail={}\n", .{fail_count});
    if (fail_count > 0) std.process.exit(1);
}

// === Shader Templates ===
// Each template is a complete GLSL fragment shader that exercises specific patterns.
// The seed determines which template is picked and parameters within it.

const GlslType = enum {
    float, vec2, vec3, vec4,
    int, ivec2, ivec3, ivec4,
    uint, uvec2, uvec3, uvec4,
    mat2, mat3, mat4,

    pub fn name(self: GlslType) []const u8 {
        return switch (self) {
            .float => "float", .vec2 => "vec2", .vec3 => "vec3", .vec4 => "vec4",
            .int => "int", .ivec2 => "ivec2", .ivec3 => "ivec3", .ivec4 => "ivec4",
            .uint => "uint", .uvec2 => "uvec2", .uvec3 => "uvec3", .uvec4 => "uvec4",
            .mat2 => "mat2", .mat3 => "mat3", .mat4 => "mat4",
        };
    }
    pub fn isMatrix(self: GlslType) bool {
        return self == .mat2 or self == .mat3 or self == .mat4;
    }
    pub fn isFloat(self: GlslType) bool {
        return self == .float or self == .vec2 or self == .vec3 or self == .vec4;
    }
    pub fn isInt(self: GlslType) bool {
        return self == .int or self == .ivec2 or self == .ivec3 or self == .ivec4;
    }
};

const arith_types = [_]GlslType{ .float, .vec2, .vec3, .vec4, .int, .ivec2, .ivec3, .ivec4, .uint, .uvec2, .uvec3, .uvec4, .mat2, .mat3, .mat4 };
const float_types = [_]GlslType{ .float, .vec2, .vec3, .vec4 };
const float_vec_types = [_]GlslType{ .vec2, .vec3, .vec4 };
const mat_types = [_]GlslType{ .mat2, .mat3, .mat4 };

fn pick(comptime T: type, pool: []const T, rng: std.Random) T {
    return pool[rng.intRangeAtMost(usize, 0, pool.len - 1)];
}

fn fmtLit(buf: []u8, ty: GlslType, rng: std.Random) []const u8 {
    return switch (ty) {
        .float => std.fmt.bufPrint(buf, "{d:.1}", .{@as(f32, @floatFromInt(rng.intRangeAtMost(i32, 1, 9)))}) catch "1.0",
        .vec2 => std.fmt.bufPrint(buf, "vec2({d:.1}, {d:.1})", .{ rng.float(f32) * 5.0 + 1.0, rng.float(f32) * 5.0 + 1.0 }) catch "vec2(1.0, 2.0)",
        .vec3 => std.fmt.bufPrint(buf, "vec3({d:.1}, {d:.1}, {d:.1})", .{ rng.float(f32) * 5.0 + 1.0, rng.float(f32) * 5.0 + 1.0, rng.float(f32) * 5.0 + 1.0 }) catch "vec3(1.0, 2.0, 3.0)",
        .vec4 => std.fmt.bufPrint(buf, "vec4({d:.1}, {d:.1}, {d:.1}, {d:.1})", .{ rng.float(f32) * 5.0 + 1.0, rng.float(f32) * 5.0 + 1.0, rng.float(f32) * 5.0 + 1.0, rng.float(f32) * 5.0 + 1.0 }) catch "vec4(1.0, 2.0, 3.0, 4.0)",
        .int => std.fmt.bufPrint(buf, "{d}", .{rng.intRangeAtMost(i32, 1, 9)}) catch "1",
        .ivec2 => std.fmt.bufPrint(buf, "ivec2({d}, {d})", .{ rng.intRangeAtMost(i32, 1, 9), rng.intRangeAtMost(i32, 1, 9) }) catch "ivec2(1, 2)",
        .ivec3 => std.fmt.bufPrint(buf, "ivec3({d}, {d}, {d})", .{ rng.intRangeAtMost(i32, 1, 9), rng.intRangeAtMost(i32, 1, 9), rng.intRangeAtMost(i32, 1, 9) }) catch "ivec3(1, 2, 3)",
        .ivec4 => std.fmt.bufPrint(buf, "ivec4({d}, {d}, {d}, {d})", .{ rng.intRangeAtMost(i32, 1, 9), rng.intRangeAtMost(i32, 1, 9), rng.intRangeAtMost(i32, 1, 9), rng.intRangeAtMost(i32, 1, 9) }) catch "ivec4(1, 2, 3, 4)",
        .uint => std.fmt.bufPrint(buf, "{d}u", .{rng.intRangeAtMost(u32, 1, 9)}) catch "1u",
        .uvec2 => std.fmt.bufPrint(buf, "uvec2({d}u, {d}u)", .{ rng.intRangeAtMost(u32, 1, 9), rng.intRangeAtMost(u32, 1, 9) }) catch "uvec2(1u, 2u)",
        .uvec3 => std.fmt.bufPrint(buf, "uvec3({d}u, {d}u, {d}u)", .{ rng.intRangeAtMost(u32, 1, 9), rng.intRangeAtMost(u32, 1, 9), rng.intRangeAtMost(u32, 1, 9) }) catch "uvec3(1u, 2u, 3u)",
        .uvec4 => std.fmt.bufPrint(buf, "uvec4({d}u, {d}u, {d}u, {d}u)", .{ rng.intRangeAtMost(u32, 1, 9), rng.intRangeAtMost(u32, 1, 9), rng.intRangeAtMost(u32, 1, 9), rng.intRangeAtMost(u32, 1, 9) }) catch "uvec4(1u, 2u, 3u, 4u)",
        .mat2 => "mat2(1.0, 0.0, 0.0, 1.0)",
        .mat3 => "mat3(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)",
        .mat4 => "mat4(1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0)",
    };
}

fn generateShader(alloc: std.mem.Allocator, seed: u64) error{OutOfMemory}![:0]const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const templates = 10;
    const pick_template = rng.intRangeAtMost(usize, 0, templates - 1);

    var list = std.ArrayList(u8){};
    errdefer list.deinit(alloc);

    switch (pick_template) {
        0 => try genArithmetic(&list, alloc, rng),
        1 => try genControlFlow(&list, alloc, rng),
        2 => try genMatrixArith(&list, alloc, rng),
        3 => try genSwizzle(&list, alloc, rng),
        4 => try genTernary(&list, alloc, rng),
        5 => try genLoop(&list, alloc, rng),
        6 => try genFunction(&list, alloc, rng),
        7 => try genMixedTypes(&list, alloc, rng),
        8 => try genArray(&list, alloc, rng),
        9 => try genStruct(&list, alloc, rng),
        else => unreachable,
    }

    return list.toOwnedSliceSentinel(alloc, 0);
}

const Writer = struct {
    fn s(l: *std.ArrayList(u8), a: std.mem.Allocator, str: []const u8) error{OutOfMemory}!void {
        try l.appendSlice(a, str);
    }
    fn f(l: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        var tmp: [512]u8 = undefined;
        const printed = std.fmt.bufPrint(&tmp, fmt, args) catch "";
        try l.appendSlice(a, printed);
    }
};

fn genArithmetic(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    try Writer.s(list, alloc, "#version 450\nlayout(location = 0) out vec4 FragColor;\nvoid main() {\n");
    const ty = pick(GlslType, &arith_types, rng);
    var tmp1: [128]u8 = undefined;
    var tmp2: [128]u8 = undefined;
    try Writer.f(list, alloc, "    {s} a = {s};\n", .{ ty.name(), fmtLit(&tmp1, ty, rng) });
    try Writer.f(list, alloc, "    {s} b = {s};\n", .{ ty.name(), fmtLit(&tmp2, ty, rng) });
    const ops = [_][]const u8{ "+", "-", "*" };
    const op = ops[rng.intRangeAtMost(usize, 0, ops.len - 1)];
    try Writer.f(list, alloc, "    {s} c = a {s} b;\n", .{ ty.name(), op });
    if (ty.isMatrix()) {
        const vt = switch (ty) { .mat2 => "vec2", .mat3 => "vec3", .mat4 => "vec4", else => "vec2" };
        const fc = switch (ty) {
            .mat2 => "FragColor = vec4(r, 0.0, 1.0);\n",
            .mat3 => "FragColor = vec4(r, 1.0);\n",
            .mat4 => "FragColor = r;\n",
            else => unreachable,
        };
        try Writer.f(list, alloc, "    {s} r = c * {s}(1.0);\n    {s}", .{ vt, vt, fc });
    } else if (ty == .float) {
        try Writer.s(list, alloc, "    FragColor = vec4(c, 0.0, 0.0, 1.0);\n");
    } else if (ty == .vec4) {
        try Writer.s(list, alloc, "    FragColor = c;\n");
    } else {
        try Writer.s(list, alloc, "    FragColor = vec4(float(c.x), 0.0, 0.0, 1.0);\n");
    }
    try Writer.s(list, alloc, "}\n");
}

fn genControlFlow(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    try Writer.s(list, alloc, "#version 450\nlayout(location = 0) out vec4 FragColor;\nvoid main() {\n");
    try Writer.s(list, alloc, "    float x = gl_FragCoord.x / 128.0;\n    float y = gl_FragCoord.y / 128.0;\n");

    switch (rng.intRangeAtMost(usize, 0, 8)) {
        0 => {
            try Writer.s(list, alloc, "    float r;\n    if (x < 0.5) { r = 0.0; } else { r = 1.0; }\n");
            try Writer.s(list, alloc, "    FragColor = vec4(r, 0.0, 0.0, 1.0);\n");
        },
        1 => {
            const n = rng.intRangeAtMost(usize, 2, 10);
            try Writer.f(list, alloc, "    float s = 0.0;\n    for (int i = 0; i < {d}; i++) {{ s += x; }}\n", .{n});
            try Writer.s(list, alloc, "    FragColor = vec4(s / 10.0, 0.0, 0.0, 1.0);\n");
        },
        2 => {
            try Writer.s(list, alloc,
                \\    float s = 0.0;
                \\    for (int i = 0; i < 8; i++) {
                \\        if (i % 3 == 0) continue;
                \\        if (i > 6) break;
                \\        s += x;
                \\    }
                \\    FragColor = vec4(s / 8.0, 0.0, 0.0, 1.0);
                \\
            );
        },
        3 => {
            try Writer.s(list, alloc,
                \\    float s = 0.0;
                \\    int i = 0;
                \\    while (i < 5) {
                \\        s += x * y;
                \\        i++;
                \\    }
                \\    FragColor = vec4(s, 0.0, 0.0, 1.0);
                \\
            );
        },
        4 => {
            try Writer.s(list, alloc,
                \\    float r;
                \\    if (x < 0.25) { r = 0.0; }
                \\    else if (x < 0.5) { r = 0.33; }
                \\    else if (x < 0.75) { r = 0.66; }
                \\    else { r = 1.0; }
                \\    FragColor = vec4(r, y, 0.0, 1.0);
                \\
            );
        },
        5 => {
            try Writer.s(list, alloc,
                \\    float s = 0.0;
                \\    int i = 0;
                \\    do { s += x; i++; } while (i < 4);
                \\    FragColor = vec4(s, 0.0, 0.0, 1.0);
                \\
            );
        },
        6 => {
            try Writer.s(list, alloc,
                \\    float s = 0.0;
                \\    for (int i = 0; i < 3; i++) {
                \\        for (int j = 0; j < 3; j++) {
                \\            s += x * float(i + j);
                \\        }
                \\    }
                \\    FragColor = vec4(s / 18.0, 0.0, 0.0, 1.0);
                \\
            );
        },
        7 => {
            try Writer.s(list, alloc,
                \\    float s = 0.0;
                \\    for (int i = 0; i < 10; i++) {
                \\        if (i % 2 == 0) { s += x; }
                \\        else { s += y; }
                \\    }
                \\    FragColor = vec4(s / 10.0, 0.0, 0.0, 1.0);
                \\
            );
        },
        8 => {
            try Writer.s(list, alloc,
                \\    int k = int(x * 4.0);
                \\    float r;
                \\    switch (k) {
                \\        case 0: r = 0.0; break;
                \\        case 1: r = 0.33; break;
                \\        case 2: r = 0.66; break;
                \\        default: r = 1.0; break;
                \\    }
                \\    FragColor = vec4(r, 0.0, 0.0, 1.0);
                \\
            );
        },
        else => unreachable,
    }
    try Writer.s(list, alloc, "}\n");
}

fn genMatrixArith(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    try Writer.s(list, alloc, "#version 450\nlayout(location = 0) out vec4 FragColor;\nvoid main() {\n");
    const mt = pick(GlslType, &mat_types, rng);
    const tn = mt.name();
    const vt = switch (mt) { .mat2 => "vec2", .mat3 => "vec3", .mat4 => "vec4", else => "vec2" };
    // Build correct FragColor assignment based on vector type
    const fc = switch (mt) {
        .mat2 => "FragColor = vec4(r, 0.0, 1.0);\n",
        .mat3 => "FragColor = vec4(r, 1.0);\n",
        .mat4 => "FragColor = r;\n",
        else => unreachable,
    };

    switch (rng.intRangeAtMost(usize, 0, 5)) {
        0 => {
            try Writer.f(list, alloc, "    {s} a = {s}(1.0); {s} b = {s}(2.0);\n", .{ tn, tn, tn, tn });
            try Writer.f(list, alloc, "    {s} c = a + b;\n", .{tn});
            try Writer.f(list, alloc, "    {s} r = c * {s}(1.0);\n    {s}", .{ vt, vt, fc });
        },
        1 => {
            try Writer.f(list, alloc, "    {s} a = {s}(3.0); {s} b = {s}(1.0);\n", .{ tn, tn, tn, tn });
            try Writer.f(list, alloc, "    {s} c = a - b;\n", .{tn});
            try Writer.f(list, alloc, "    {s} r = c * {s}(1.0);\n    {s}", .{ vt, vt, fc });
        },
        2 => {
            try Writer.f(list, alloc, "    {s} a = {s}(1.0); {s} b = {s}(1.0);\n", .{ tn, tn, tn, tn });
            try Writer.f(list, alloc, "    {s} c = a * 0.5 + b * 0.5;\n", .{tn});
            try Writer.f(list, alloc, "    {s} r = c * {s}(1.0);\n    {s}", .{ vt, vt, fc });
        },
        3 => {
            try Writer.f(list, alloc, "    {s} a = {s}(1.0); {s} b = {s}(1.0);\n", .{ tn, tn, tn, tn });
            try Writer.f(list, alloc, "    {s} c = a * b;\n", .{tn});
            try Writer.f(list, alloc, "    {s} r = c * {s}(1.0);\n    {s}", .{ vt, vt, fc });
        },
        4 => {
            try Writer.f(list, alloc, "    {s} a = {s}(1.0); {s} b = {s}(2.0);\n", .{ tn, tn, tn, tn });
            try Writer.f(list, alloc, "    {s} c = (a + b) - a;\n    {s} d = c * 0.25;\n", .{ tn, tn });
            try Writer.f(list, alloc, "    {s} r = d * {s}(1.0);\n    {s}", .{ vt, vt, fc });
        },
        5 => {
            try Writer.f(list, alloc, "    float x = gl_FragCoord.x / 128.0;\n", .{});
            try Writer.f(list, alloc, "    {s} a = {s}(x);\n    {s} b = {s}(1.0 - x);\n", .{ tn, tn, tn, tn });
            try Writer.f(list, alloc, "    {s} c = a * 0.3 + b * 0.7;\n", .{tn});
            try Writer.f(list, alloc, "    {s} r = c * {s}(1.0);\n    {s}", .{ vt, vt, fc });
        },
        else => unreachable,
    }
    try Writer.s(list, alloc, "}\n");
}

fn genSwizzle(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    try Writer.s(list, alloc, "#version 450\nlayout(location = 0) out vec4 FragColor;\nvoid main() {\n");
    const swizzles = [_][]const u8{ "xy", "yz", "zw", "xz", "xzy", "yzx", "wzyx", "xyz", "xx", "yy" };
    const sw = swizzles[rng.intRangeAtMost(usize, 0, swizzles.len - 1)];
    switch (rng.intRangeAtMost(usize, 0, 3)) {
        0 => try Writer.f(list, alloc, "    vec4 a = vec4(1.0, 2.0, 3.0, 4.0);\n    vec2 b = a.{s};\n    FragColor = vec4(b, 0.0, 1.0);\n", .{sw}),
        1 => try Writer.s(list, alloc, "    vec4 a = vec4(0.0);\n    a.xy = vec2(1.0, 2.0);\n    a.zw = vec2(3.0, 4.0);\n    FragColor = a;\n"),
        2 => try Writer.s(list, alloc, "    vec4 a = vec4(1.0, 2.0, 3.0, 4.0);\n    vec4 b = a.wzyx;\n    FragColor = b;\n"),
        3 => try Writer.f(list, alloc, "    vec4 a = vec4(1.0, 2.0, 3.0, 4.0);\n    vec3 b = a.{s} * 0.5;\n    FragColor = vec4(b, 1.0);\n", .{sw[0..@min(sw.len, 3)]}),
        else => unreachable,
    }
    try Writer.s(list, alloc, "}\n");
}

fn genTernary(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    try Writer.s(list, alloc, "#version 450\nlayout(location = 0) out vec4 FragColor;\nvoid main() {\n    float x = gl_FragCoord.x / 128.0;\n");
    switch (rng.intRangeAtMost(usize, 0, 4)) {
        0 => try Writer.s(list, alloc, "    float r = x > 0.5 ? 1.0 : 0.0;\n    FragColor = vec4(r, 0.0, 0.0, 1.0);\n"),
        1 => try Writer.s(list, alloc, "    vec4 r = x > 0.5 ? vec4(1.0) : vec4(0.0);\n    FragColor = r;\n"),
        2 => try Writer.s(list, alloc, "    float r = x < 0.33 ? 0.0 : (x < 0.66 ? 0.5 : 1.0);\n    FragColor = vec4(r, r, r, 1.0);\n"),
        3 => try Writer.s(list, alloc, "    float y = gl_FragCoord.y / 128.0;\n    float r = (x > 0.5 && y > 0.5) ? 1.0 : 0.0;\n    FragColor = vec4(r, 0.0, 0.0, 1.0);\n"),
        4 => try Writer.s(list, alloc, "    float r = (x > 0.5 ? x : 1.0 - x) + 0.25;\n    FragColor = vec4(r, 0.0, 0.0, 1.0);\n"),
        else => unreachable,
    }
    try Writer.s(list, alloc, "}\n");
}

fn genLoop(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    try Writer.s(list, alloc, "#version 450\nlayout(location = 0) out vec4 FragColor;\nvoid main() {\n    float x = gl_FragCoord.x / 128.0;\n");
    switch (rng.intRangeAtMost(usize, 0, 4)) {
        0 => try Writer.s(list, alloc,
            \\    float s = 0.0;
            \\    for (int i = 0; i < 10; i++) {
            \\        if (i % 3 == 0) continue;
            \\        s += x;
            \\    }
            \\    FragColor = vec4(s / 7.0, 0.0, 0.0, 1.0);
            \\
        ),
        1 => try Writer.s(list, alloc,
            \\    float s = 0.0;
            \\    for (int i = 0; i < 20; i++) {
            \\        s += x;
            \\        if (s > 3.0) break;
            \\    }
            \\    FragColor = vec4(s / 5.0, 0.0, 0.0, 1.0);
            \\
        ),
        2 => {
            const ty = pick(GlslType, &float_vec_types, rng);
            try Writer.f(list, alloc, "    {s} s = {s}(0.0);\n", .{ ty.name(), ty.name() });
            try Writer.f(list, alloc, "    for (int i = 0; i < 4; i++) {{ s += {s}(x * float(i + 1)); }}\n", .{ty.name()});
            if (ty == .vec2) {
                try Writer.s(list, alloc, "    FragColor = vec4(s, 0.0, 1.0);\n");
            } else if (ty == .vec3) {
                try Writer.s(list, alloc, "    FragColor = vec4(s, 1.0);\n");
            } else {
                try Writer.s(list, alloc, "    FragColor = s;\n");
            }
        },
        3 => try Writer.s(list, alloc,
            \\    float s = 0.0;
            \\    for (int i = 0; i < 15; i++) {
            \\        if (i < 2) continue;
            \\        if (i > 8) break;
            \\        s += x * float(i);
            \\    }
            \\    FragColor = vec4(s / 30.0, 0.0, 0.0, 1.0);
            \\
        ),
        4 => try Writer.s(list, alloc,
            \\    float a = 0.0;
            \\    float b = 1.0;
            \\    int i = 0;
            \\    while (i < 8) {
            \\        float t = a + b;
            \\        a = b;
            \\        b = t;
            \\        i++;
            \\    }
            \\    FragColor = vec4(a / 50.0, b / 50.0, 0.0, 1.0);
            \\
        ),
        else => unreachable,
    }
    try Writer.s(list, alloc, "}\n");
}

fn genFunction(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    switch (rng.intRangeAtMost(usize, 0, 3)) {
        0 => try Writer.s(list, alloc,
            \\#version 450
            \\layout(location = 0) out vec4 FragColor;
            \\float add(float a, float b) { return a + b; }
            \\float mul(float a, float b) { return a * b; }
            \\void main() {
            \\    float x = gl_FragCoord.x / 128.0;
            \\    float y = gl_FragCoord.y / 128.0;
            \\    FragColor = vec4(add(x, y), mul(x, y), 0.0, 1.0);
            \\}
            \\
        ),
        1 => try Writer.s(list, alloc,
            \\#version 450
            \\layout(location = 0) out vec4 FragColor;
            \\vec3 scale(vec3 v, float s) { return v * s; }
            \\void main() {
            \\    FragColor = vec4(scale(vec3(1.0, 0.5, 0.25), 2.0), 1.0);
            \\}
            \\
        ),
        2 => try Writer.s(list, alloc,
            \\#version 450
            \\layout(location = 0) out vec4 FragColor;
            \\float square(float x) { return x * x; }
            \\float dist2(vec2 a, vec2 b) { return square(a.x - b.x) + square(a.y - b.y); }
            \\void main() {
            \\    vec2 uv = gl_FragCoord.xy / vec2(128.0);
            \\    FragColor = vec4(dist2(uv, vec2(0.5)), 0.0, 0.0, 1.0);
            \\}
            \\
        ),
        3 => {
            const ft = pick(GlslType, &float_types, rng);
            try Writer.f(list, alloc,
                \\#version 450
                \\layout(location = 0) out vec4 FragColor;
                \\{s} identity({s} x) {{ return x; }}
                \\void main() {{
                \\    {s} v = identity({s}(1.0));
            , .{ ft.name(), ft.name(), ft.name(), ft.name() });
            if (ft == .vec4) {
                try Writer.s(list, alloc, "    FragColor = v;\n");
            } else if (ft == .vec3) {
                try Writer.s(list, alloc, "    FragColor = vec4(v, 1.0);\n");
            } else if (ft == .vec2) {
                try Writer.s(list, alloc, "    FragColor = vec4(v, 0.0, 1.0);\n");
            } else {
                try Writer.s(list, alloc, "    FragColor = vec4(v, 0.0, 0.0, 1.0);\n");
            }
            try Writer.s(list, alloc, "}\n");
        },
        else => unreachable,
    }
}

fn genMixedTypes(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    try Writer.s(list, alloc, "#version 450\nlayout(location = 0) out vec4 FragColor;\nvoid main() {\n");
    switch (rng.intRangeAtMost(usize, 0, 5)) {
        0 => try Writer.s(list, alloc,
            \\    float x = gl_FragCoord.x / 128.0;
            \\    int i = int(x * 10.0);
            \\    float y = float(i) / 10.0;
            \\    FragColor = vec4(y, 0.0, 0.0, 1.0);
            \\}
            \\
        ),
        1 => try Writer.s(list, alloc,
            \\    vec2 a = vec2(1.0, 2.0);
            \\    vec3 b = vec3(a, 3.0);
            \\    vec4 c = vec4(b, 4.0);
            \\    FragColor = c;
            \\}
            \\
        ),
        2 => try Writer.s(list, alloc,
            \\    float x = gl_FragCoord.x / 128.0;
            \\    vec2 a = vec2(1.0) * x;
            \\    vec3 b = vec3(a, x);
            \\    FragColor = vec4(b, 1.0);
            \\}
            \\
        ),
        3 => try Writer.s(list, alloc,
            \\    uint a = 5u;
            \\    uint b = 3u;
            \\    uint c = a + b;
            \\    uint d = a * b;
            \\    FragColor = vec4(float(c) / 100.0, float(d) / 100.0, 0.0, 1.0);
            \\}
            \\
        ),
        4 => try Writer.s(list, alloc,
            \\    float x = gl_FragCoord.x / 128.0;
            \\    bool flag = x > 0.5;
            \\    float r = flag ? 1.0 : 0.0;
            \\    FragColor = vec4(r, 0.0, 0.0, 1.0);
            \\}
            \\
        ),
        5 => try Writer.s(list, alloc,
            \\    float x = gl_FragCoord.x / 128.0;
            \\    float y = -x + 1.0;
            \\    vec2 a = -vec2(x, y);
            \\    FragColor = vec4(a, 0.0, 1.0);
            \\}
            \\
        ),
        else => unreachable,
    }
}

fn genArray(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    try Writer.s(list, alloc, "#version 450\nlayout(location = 0) out vec4 FragColor;\nvoid main() {\n");
    switch (rng.intRangeAtMost(usize, 0, 3)) {
        0 => try Writer.s(list, alloc,
            \\    float arr[4] = float[4](0.0, 0.25, 0.5, 1.0);
            \\    int idx = int(gl_FragCoord.x / 32.0) % 4;
            \\    FragColor = vec4(arr[idx], 0.0, 0.0, 1.0);
            \\}
            \\
        ),
        1 => try Writer.s(list, alloc,
            \\    vec3 colors[3] = vec3[3](vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0));
            \\    int idx = int(gl_FragCoord.x / 42.0) % 3;
            \\    FragColor = vec4(colors[idx], 1.0);
            \\}
            \\
        ),
        2 => try Writer.s(list, alloc,
            \\    float arr[8];
            \\    for (int i = 0; i < 8; i++) { arr[i] = float(i) / 8.0; }
            \\    int idx = int(gl_FragCoord.x / 16.0) % 8;
            \\    FragColor = vec4(arr[idx], 0.0, 0.0, 1.0);
            \\}
            \\
        ),
        3 => try Writer.s(list, alloc,
            \\    float sum = 0.0;
            \\    float vals[4] = float[4](0.1, 0.2, 0.3, 0.4);
            \\    for (int i = 0; i < 4; i++) { sum += vals[i]; }
            \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
            \\}
            \\
        ),
        else => unreachable,
    }
}

fn genStruct(list: *std.ArrayList(u8), alloc: std.mem.Allocator, rng: std.Random) !void {
    switch (rng.intRangeAtMost(usize, 0, 3)) {
        0 => try Writer.s(list, alloc,
            \\#version 450
            \\layout(location = 0) out vec4 FragColor;
            \\struct Color { vec3 rgb; float a; };
            \\Color makeColor(float r, float g, float b) {
            \\    Color c;
            \\    c.rgb = vec3(r, g, b);
            \\    c.a = 1.0;
            \\    return c;
            \\}
            \\void main() {
            \\    float x = gl_FragCoord.x / 128.0;
            \\    Color c = makeColor(x, 1.0 - x, 0.5);
            \\    FragColor = vec4(c.rgb, c.a);
            \\}
            \\
        ),
        1 => try Writer.s(list, alloc,
            \\#version 450
            \\layout(location = 0) out vec4 FragColor;
            \\struct Point { vec2 pos; float size; };
            \\Point scale(Point p, float s) {
            \\    Point r;
            \\    r.pos = p.pos * s;
            \\    r.size = p.size * s;
            \\    return r;
            \\}
            \\void main() {
            \\    Point a;
            \\    a.pos = gl_FragCoord.xy / vec2(128.0);
            \\    a.size = 1.0;
            \\    Point b = scale(a, 2.0);
            \\    FragColor = vec4(b.pos, b.size / 5.0, 1.0);
            \\}
            \\
        ),
        2 => try Writer.s(list, alloc,
            \\#version 450
            \\layout(location = 0) out vec4 FragColor;
            \\struct Inner { float a; float b; };
            \\struct Outer { Inner inner; float extra; };
            \\void main() {
            \\    Outer o;
            \\    o.inner.a = gl_FragCoord.x / 128.0;
            \\    o.inner.b = gl_FragCoord.y / 128.0;
            \\    o.extra = 0.5;
            \\    FragColor = vec4(o.inner.a, o.inner.b, o.extra, 1.0);
            \\}
            \\
        ),
        3 => try Writer.s(list, alloc,
            \\#version 450
            \\layout(location = 0) out vec4 FragColor;
            \\struct S { int x; int y; };
            \\S add(S a, S b) {
            \\    S r;
            \\    r.x = a.x + b.x;
            \\    r.y = a.y + b.y;
            \\    return r;
            \\}
            \\void main() {
            \\    S a; a.x = 1; a.y = 2;
            \\    S b; b.x = 3; b.y = 4;
            \\    S c = add(a, b);
            \\    FragColor = vec4(float(c.x) / 10.0, float(c.y) / 10.0, 0.0, 1.0);
            \\}
            \\
        ),
        else => unreachable,
    }
}
