// SPDX-License-Identifier: MIT
//! Output comparison tests: glslpp vs spirv-cross.
//!
//! For each test shader, compiles GLSL → SPIR-V (via glslangValidator),
//! then cross-compiles the SAME SPIR-V with both glslpp and spirv-cross.
//! Compares key structural elements to ensure semantic equivalence.
//!
//! Requires:
//!   - glslangValidator in PATH or VULKAN_SDK
//!   - spirv-cross in PATH or VULKAN_SDK

const std = @import("std");
const glslpp = @import("glslpp");
const compat = @import("glslpp").compat;

const alloc = std.testing.allocator;

/// Compile GLSL to SPIR-V using glslangValidator, return the SPIR-V words
fn compileToSpirvViaGlslang(allocator: std.mem.Allocator, source: [:0]const u8, stage: glslpp.Stage) ![]u32 {
    const io = compat.testIo();
    const dir = compat.cwd();

    // Ensure .zig-cache exists
    compat.dirMakePath(io, dir, ".zig-cache") catch {};

    // Write source to temp file
    var tmp_buf: [compat.max_path_bytes]u8 = undefined;
    const ext = switch (stage) {
        .vertex => ".vert",
        .fragment => ".frag",
        .compute => ".comp",
        else => ".frag",
    };
    const tmp_path_ext = std.fmt.bufPrint(&tmp_buf, ".zig-cache/cc{d}{s}", .{ compat.randomInt(u32), ext }) catch return error.OutOfMemory;

    const tmp_file = compat.dirCreateFile(io, dir, tmp_path_ext, .{}) catch |err| {
        return err;
    };
    compat.fileWriteAll(io, tmp_file, std.mem.sliceTo(source, 0)) catch {};
    compat.fileClose(io, tmp_file); // Close before running external tool (Windows file locking)

    // Run glslangValidator
    const spv_path = try std.fmt.allocPrint(allocator, "{s}.spv", .{tmp_path_ext});
    defer allocator.free(spv_path);

    const glslang = compat.resolveVulkanTool(allocator, "glslangValidator") catch return error.SkipZigTest;
    defer allocator.free(glslang);
    const result = compat.processRun(io, allocator, &.{ glslang, "-V", "-o", spv_path, tmp_path_ext }) catch return error.SkipZigTest;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Read SPIR-V output
    compat.dirDeleteFile(io, dir, tmp_path_ext) catch {};
    const spv_file = compat.dirOpenFile(io, dir, spv_path, .{}) catch {
        std.debug.print("glslangValidator stderr: {s}\n", .{result.stderr});
        return error.FileNotFound;
    };
    defer compat.fileClose(io, spv_file);
    defer compat.dirDeleteFile(io, dir, spv_path) catch {};

    const spv_bytes = try compat.fileReadToEndAlloc(io, spv_file, allocator, 10 * 1024 * 1024);
    // bytes may not be 4-aligned, so copy into properly aligned slice
    const word_count = spv_bytes.len / 4;
    const spv_words = try allocator.alloc(u32, word_count);
    for (0..word_count) |i| {
        spv_words[i] = std.mem.readInt(u32, spv_bytes[i * 4 ..][0..4], .little);
    }
    allocator.free(spv_bytes);
    return spv_words;
}

/// Cross-compile SPIR-V to GLSL using spirv-cross CLI at the default version (450).
fn spirvCrossToGlsl(allocator: std.mem.Allocator, spirv: []const u32) ![]u8 {
    return spirvCrossToGlslVersion(allocator, spirv, 450, true);
}

/// Cross-compile SPIR-V to GLSL using spirv-cross CLI at a chosen desktop version.
/// `vulkan_semantics` matches the original default-450 caller; structural-compare
/// callers pass `false` for plain desktop GLSL (Vulkan semantics would otherwise
/// keep `layout(binding=)` at every version and change the 420pack guard logic).
fn spirvCrossToGlslVersion(allocator: std.mem.Allocator, spirv: []const u32, version: u32, vulkan_semantics: bool) ![]u8 {
    const io = compat.testIo();
    const dir = compat.cwd();

    // Write SPIR-V to temp file
    var tmp_buf_sc: [compat.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf_sc, ".zig-cache/spircross-{}.spv", .{compat.randomInt(u64)}) catch return error.OutOfMemory;
    compat.dirWriteFile(io, dir, tmp_path, std.mem.sliceAsBytes(spirv)) catch return error.OutOfMemory;
    defer compat.dirDeleteFile(io, dir, tmp_path) catch {};

    var ver_buf: [16]u8 = undefined;
    const ver_str = std.fmt.bufPrint(&ver_buf, "{d}", .{version}) catch return error.OutOfMemory;
    const spirv_cross = compat.resolveVulkanTool(allocator, "spirv-cross") catch return error.SkipZigTest;
    defer allocator.free(spirv_cross);
    const result = if (vulkan_semantics)
        compat.processRun(io, allocator, &.{ spirv_cross, tmp_path, "--version", ver_str, "--vulkan-semantics" }) catch return error.SkipZigTest
    else
        compat.processRun(io, allocator, &.{ spirv_cross, tmp_path, "--version", ver_str }) catch return error.SkipZigTest;
    defer allocator.free(result.stderr);
    return result.stdout;
}

/// Normalize GLSL output for comparison:
/// - Strip comments
/// - Normalize whitespace
/// - Lowercase
fn normalizeGlsl(allocator: std.mem.Allocator, glsl: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, glsl.len);
    errdefer allocator.free(result);

    var i: usize = 0;
    var out: usize = 0;
    var in_line_comment = false;
    var in_block_comment = false;
    var last_was_space = false;

    while (i < glsl.len) {
        const ch = glsl[i];

        if (in_block_comment) {
            if (ch == '*' and i + 1 < glsl.len and glsl[i + 1] == '/') {
                in_block_comment = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }

        if (in_line_comment) {
            if (ch == '\n') {
                in_line_comment = false;
            } else {
                i += 1;
                continue;
            }
        }

        if (ch == '/' and i + 1 < glsl.len) {
            if (glsl[i + 1] == '/') {
                in_line_comment = true;
                i += 2;
                continue;
            }
            if (glsl[i + 1] == '*') {
                in_block_comment = true;
                i += 2;
                continue;
            }
        }

        if (ch == ' ' or ch == '\t' or ch == '\r') {
            if (!last_was_space and out < result.len) {
                result[out] = ' ';
                out += 1;
                last_was_space = true;
            }
            i += 1;
            continue;
        }

        if (ch == '\n') {
            if (out < result.len) {
                result[out] = '\n';
                out += 1;
            }
            last_was_space = false;
            i += 1;
            continue;
        }

        if (out < result.len) {
            result[out] = std.ascii.toLower(ch);
            out += 1;
        }
        last_was_space = false;
        i += 1;
    }

    return allocator.realloc(result, out);
}

/// Extract key operations from normalized GLSL
/// Returns a set of normalized operation strings
fn extractOperations(allocator: std.mem.Allocator, glsl: []const u8) !std.StringHashMap(void) {
    var ops = std.StringHashMap(void).init(allocator);
    errdefer {
        var it = ops.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        ops.deinit();
    }

    // Extract lines containing key operations (assignments, function calls, declarations)
    var lines = std.mem.splitSequence(u8, glsl, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue; // preprocessor
        if (std.mem.startsWith(u8, trimmed, "precision")) continue;
        if (std.mem.eql(u8, trimmed, "{") or std.mem.eql(u8, trimmed, "}")) continue;

        // Check for key patterns
        const is_interesting =
            std.mem.indexOf(u8, trimmed, "uniform") != null or
            std.mem.indexOf(u8, trimmed, "layout") != null or
            std.mem.indexOf(u8, trimmed, "in ") != null or
            std.mem.indexOf(u8, trimmed, "out ") != null or
            std.mem.indexOf(u8, trimmed, "sampler2d") != null or
            std.mem.indexOf(u8, trimmed, "texture(") != null or
            std.mem.indexOf(u8, trimmed, "main()") != null or
            std.mem.indexOf(u8, trimmed, "= ") != null;

        if (is_interesting) {
            const owned = try allocator.dupe(u8, trimmed);
            try ops.put(owned, {});
        }
    }

    return ops;
}

const CompareResult = struct {
    glslpp_glsl: []const u8,
    sc_glsl: []const u8,
    match: bool,
    mismatches: u32,
};

/// Compare glslpp vs spirv-cross output for a shader
fn compareShader(allocator: std.mem.Allocator, name: []const u8, source: [:0]const u8, stage: glslpp.Stage) !CompareResult {
    // Step 1: GLSL → SPIR-V via glslang (shared between both)
    const spirv = compileToSpirvViaGlslang(allocator, source, stage) catch |err| {
        std.debug.print("  [{s}] glslang failed: {}\n", .{ name, err });
        return err;
    };
    defer allocator.free(spirv);

    // Step 2: SPIR-V → GLSL via glslpp
    const glslpp_glsl = glslpp.spirvToGLSL(allocator, spirv, .{ .version = 450 }) catch |err| {
        std.debug.print("  [{s}] glslpp spirvToGLSL failed: {}\n", .{ name, err });
        return err;
    };

    // Step 3: SPIR-V → GLSL via spirv-cross
    const sc_glsl = spirvCrossToGlsl(allocator, spirv) catch |err| {
        std.debug.print("  [{s}] spirv-cross failed: {}\n", .{ name, err });
        allocator.free(glslpp_glsl);
        return err;
    };

    // Step 4: Normalize both outputs
    const norm_gpp = normalizeGlsl(allocator, glslpp_glsl) catch glslpp_glsl;
    const norm_sc = normalizeGlsl(allocator, sc_glsl) catch sc_glsl;
    defer {
        if (norm_gpp.ptr != glslpp_glsl.ptr) allocator.free(norm_gpp);
        if (norm_sc.ptr != sc_glsl.ptr) allocator.free(norm_sc);
    }

    // Step 5: Check for "unhandled" in glslpp output
    var mismatches: u32 = 0;
    if (std.mem.indexOf(u8, glslpp_glsl, "unhandled") != null) {
        mismatches += 1;
        std.debug.print("  [{s}] glslpp output contains 'unhandled'\n", .{name});
    }

    // Step 6: Compare key structural elements
    // Check that both outputs reference the same inputs/outputs/uniforms
    // Extract layout qualifiers and uniform/texture references from both
    const patterns_to_check = [_][]const u8{
        "uniform",
        "sampler2d",
        "texture(",
        "main()",
    };

    for (patterns_to_check) |pattern| {
        const gpp_count = countOccurrences(norm_gpp, pattern);
        const sc_count = countOccurrences(norm_sc, pattern);
        if (gpp_count != sc_count) {
            // Allow glslpp to have more (extra uniforms from unused vars stripped by spirv-cross)
            // but flag if glslpp has fewer (missing feature)
            if (gpp_count < sc_count) {
                mismatches += 1;
                std.debug.print("  [{s}] pattern '{s}': glslpp={} < spirv-cross={} (MISSING)\n", .{ name, pattern, gpp_count, sc_count });
            }
        }
    }

    const match = mismatches == 0;
    return .{
        .glslpp_glsl = glslpp_glsl,
        .sc_glsl = sc_glsl,
        .match = match,
        .mismatches = mismatches,
    };
}

fn countOccurrences(haystack: []const u8, needle: []const u8) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| {
            count += 1;
            i = pos + needle.len;
        } else break;
    }
    return count;
}

// ============================================================================
// Tests
// ============================================================================

test "cross-compare: scalar arithmetic" {
    const source =
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = ((u.a + u.b) * u.a - u.b) / (u.a + 1.0);
        \\    fragColor = vec4(r);
        \\}
    ;
    const result = try compareShader(alloc, "scalar_arith", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: vector operations" {
    const source =
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 r = u.a * u.b + vec4(1.0, 2.0, 3.0, 4.0);
        \\    fragColor = r;
        \\}
    ;
    const result = try compareShader(alloc, "vector_ops", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: branching" {
    const source =
        \\#version 450
        \\layout(location = 0) in float u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r;
        \\    if (u > 0.5) {
        \\        r = u * 2.0;
        \\    } else {
        \\        r = u + 1.0;
        \\    }
        \\    fragColor = vec4(r);
        \\}
    ;
    const result = try compareShader(alloc, "branching", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: for loop" {
    const source =
        \\#version 450
        \\layout(location = 0) in float u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        sum += u + float(i);
        \\    }
        \\    fragColor = vec4(sum);
        \\}
    ;
    const result = try compareShader(alloc, "for_loop", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: texture sampling" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 c = texture(tex, uv);
        \\    fragColor = c;
        \\}
    ;
    const result = try compareShader(alloc, "texture", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: struct with uniform" {
    const source =
        \\#version 450
        \\struct Light {
        \\    vec3 pos;
        \\    vec3 color;
        \\    float intensity;
        \\};
        \\layout(binding = 0, std140) uniform U { Light light; vec3 ambient; } u;
        \\layout(location = 0) in vec3 normal;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float d = max(dot(normal, normalize(u.light.pos)), 0.0);
        \\    vec3 color = u.ambient + u.light.color * u.light.intensity * d;
        \\    fragColor = vec4(color, 1.0);
        \\}
    ;
    const result = try compareShader(alloc, "struct_uniform", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: math builtins" {
    const source =
        \\#version 450
        \\layout(location = 0) in float u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float a = sin(u);
        \\    float b = cos(u);
        \\    float c = pow(u, 2.0);
        \\    float d = clamp(u, 0.0, 1.0);
        \\    float e = mix(0.0, 1.0, u);
        \\    float f = smoothstep(0.0, 1.0, u);
        \\    float g = length(vec2(u, 1.0));
        \\    float h = abs(u);
        \\    fragColor = vec4(a, b, c, d);
        \\}
    ;
    const result = try compareShader(alloc, "math_builtins", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: matrix operations" {
    const source =
        \\#version 450
        \\layout(binding = 0, std140) uniform U { mat4 mvp; vec4 pos; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 transformed = u.mvp * u.pos;
        \\    fragColor = transformed;
        \\}
    ;
    const result = try compareShader(alloc, "matrix", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: function call" {
    const source =
        \\#version 450
        \\layout(location = 0) in float u;
        \\layout(location = 0) out vec4 fragColor;
        \\float square(float x) { return x * x; }
        \\void main() {
        \\    float r = square(u) + square(u + 1.0);
        \\    fragColor = vec4(r);
        \\}
    ;
    const result = try compareShader(alloc, "func_call", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: nested loops with break" {
    const source =
        \\#version 450
        \\layout(location = 0) in float u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        for (int j = 0; j < 10; j++) {
        \\            sum += float(i + j) * u;
        \\            if (sum > 50.0) break;
        \\        }
        \\    }
        \\    fragColor = vec4(sum);
        \\}
    ;
    const result = try compareShader(alloc, "nested_loops", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}


test "cross-compare: branching with multiple conditions" {
    const source =
        \\#version 450
        \\layout(location = 0) in float u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r;
        \\    if (u < 0.25) { r = 1.0; }
        \\    else if (u < 0.5) { r = 0.5; }
        \\    else if (u < 0.75) { r = 0.25; }
        \\    else { r = 0.0; }
        \\    fragColor = vec4(r);
        \\}
    ;
    const result = try compareShader(alloc, "branch_multi", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: switch statement" {
    const source =
        \\#version 450
        \\layout(binding = 0, std140) uniform U { int a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r;
        \\    switch (u.a) {
        \\        case 0: r = 0.0; break;
        \\        case 1: r = 1.0; break;
        \\        case 2: r = 2.0; break;
        \\        default: r = 3.0; break;
        \\    }
        \\    fragColor = vec4(r);
        \\}
    ;
    const result = try compareShader(alloc, "switch", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: while loop with uniform bound" {
    const source =
        \\#version 450
        \\layout(binding = 0, std140) uniform U { int n; float x; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float sum = 0.0;
        \\    int i = 0;
        \\    while (i < u.n) {
        \\        sum += u.x * float(i);
        \\        i++;
        \\    }
        \\    fragColor = vec4(sum);
        \\}
    ;
    const result = try compareShader(alloc, "while_uniform", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

test "cross-compare: for loop with uniform bound" {
    const source =
        \\#version 450
        \\layout(binding = 0, std140) uniform U { int n; float x; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < u.n; i++) {
        \\        sum += u.x * float(i);
        \\    }
        \\    fragColor = vec4(sum);
        \\}
    ;
    const result = try compareShader(alloc, "for_uniform", source, .fragment);
    defer alloc.free(result.glslpp_glsl);
    defer alloc.free(result.sc_glsl);
    try std.testing.expect(result.match);
}

// ============================================================================
// #169 (G4): selectable GLSL output version 330–460
// ============================================================================

/// Write `glsl` to a temp file and run glslangValidator on it, asserting it
/// compiles cleanly (exit 0). This is the strongest gate: glslang itself is the
/// authority on which `#version`/`layout` combinations are legal.
fn assertGlslangAccepts(allocator: std.mem.Allocator, name: []const u8, glsl: []const u8, stage: glslpp.Stage) !void {
    const io = compat.testIo();
    const dir = compat.cwd();
    compat.dirMakePath(io, dir, ".zig-cache") catch {};

    const ext = switch (stage) {
        .vertex => ".vert",
        .fragment => ".frag",
        .compute => ".comp",
        else => ".frag",
    };
    var tmp_buf: [compat.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, ".zig-cache/acc{d}{s}", .{ compat.randomInt(u32), ext }) catch return error.OutOfMemory;
    const f = compat.dirCreateFile(io, dir, tmp_path, .{}) catch return error.FileNotFound;
    compat.fileWriteAll(io, f, glsl) catch {};
    compat.fileClose(io, f);
    defer compat.dirDeleteFile(io, dir, tmp_path) catch {};

    const stage_arg = switch (stage) {
        .vertex => "vert",
        .fragment => "frag",
        .compute => "comp",
        else => "frag",
    };
    const glslang = compat.resolveVulkanTool(allocator, "glslangValidator") catch return error.SkipZigTest;
    defer allocator.free(glslang);
    const result = compat.processRun(io, allocator, &.{ glslang, tmp_path, "-S", stage_arg }) catch return error.SkipZigTest;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = (result.term.exitedCode() orelse 1) == 0;
    if (!ok) {
        std.debug.print("\n[{s}] glslangValidator REJECTED glslpp output:\n{s}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ name, glsl, result.stdout, result.stderr });
        return error.GlslangRejected;
    }
}

/// Compile GLSL → SPIR-V (glslang) → GLSL (glslpp at `version`), then assert
/// glslang accepts the round-tripped output.
fn roundTripAcceptsAt(allocator: std.mem.Allocator, name: []const u8, source: [:0]const u8, stage: glslpp.Stage, version: u32) !void {
    const spirv = try compileToSpirvViaGlslang(allocator, source, stage);
    defer allocator.free(spirv);
    const glsl = try glslpp.spirvToGLSL(allocator, spirv, .{ .version = version });
    defer allocator.free(glsl);
    try assertGlslangAccepts(allocator, name, glsl, stage);
}

const ubo_frag_src: [:0]const u8 =
    \\#version 450
    \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
    \\layout(location = 0) out vec4 fragColor;
    \\void main() { fragColor = u.a + u.b; }
;
const varying_frag_src: [:0]const u8 =
    \\#version 450
    \\layout(location = 0) in vec3 vColor;
    \\layout(location = 0) out vec4 fragColor;
    \\void main() { fragColor = vec4(vColor, 1.0); }
;
const attrib_vert_src: [:0]const u8 =
    \\#version 450
    \\layout(location = 0) in vec3 aPos;
    \\layout(location = 0) out vec3 vColor;
    \\void main() { vColor = aPos; gl_Position = vec4(aPos, 1.0); }
;

test "glsl-version acceptance: UBO frag valid at 330/400/410/420/440/450/460" {
    inline for (.{ 330, 400, 410, 420, 440, 450, 460 }) |v| {
        try roundTripAcceptsAt(alloc, "ubo_frag", ubo_frag_src, .fragment, v);
    }
}

test "glsl-version acceptance: fragment input varying valid at 330/400/410/420/440/450/460" {
    // 400 is the regression target for #169 BLOCKER 1: explicit `layout(location=)`
    // on a *varying* is not core GLSL until 410, so glslang rejects it at 400 (and
    // 330). The backend must drop the location below 410, not only at 330.
    inline for (.{ 330, 400, 410, 420, 440, 450, 460 }) |v| {
        try roundTripAcceptsAt(alloc, "varying_frag", varying_frag_src, .fragment, v);
    }
}

test "glsl-version acceptance: vertex attrib+varying valid at 330/410/450/460" {
    // Exercises the gl_PerVertex emission fix: the GLSL backend used to emit a
    // malformed `out gl_PerVertex ;` declaration and a leading-dot `.gl_Position =`
    // for any vertex shader that writes gl_Position. The block variable carries its
    // BuiltIn decorations on the *members* (OpMemberDecorate), so it must be skipped
    // (its members are predefined) and member access must lower to the bare gl_*
    // name — matching spirv-cross.
    inline for (.{ 330, 410, 450, 460 }) |v| {
        try roundTripAcceptsAt(alloc, "attrib_vert", attrib_vert_src, .vertex, v);
    }
}

test "glsl-version structural: 420pack guard present at 330 and 410, absent at 450" {
    // glslpp must emit the GL_ARB_shading_language_420pack guard at versions < 420
    // (so layout(binding=) validates), matching spirv-cross, and NOT at >= 420.
    const guard = "GL_ARB_shading_language_420pack";
    inline for (.{ .{ 330, true }, .{ 410, true }, .{ 420, false }, .{ 450, false } }) |pair| {
        const spirv = try compileToSpirvViaGlslang(alloc, ubo_frag_src, .fragment);
        defer alloc.free(spirv);
        const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = pair[0] });
        defer alloc.free(glsl);
        const has = std.mem.indexOf(u8, glsl, guard) != null;
        try std.testing.expectEqual(@as(bool, pair[1]), has);
    }
}

test "glsl-version structural: location dropped on frag input below 410, kept at 410+" {
    // Below 410 glslang rejects `layout(location=)` on a fragment INPUT varying, so
    // glslpp must emit bare `in` at 330 AND 400. At >= 410 the location is kept.
    // spirv-cross does the same. #169 BLOCKER 1: 400 was previously not dropped.
    const spirv = try compileToSpirvViaGlslang(alloc, varying_frag_src, .fragment);
    defer alloc.free(spirv);

    inline for (.{ 330, 400 }) |v| {
        const g = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = v });
        defer alloc.free(g);
        // glslpp must emit a bare `in vec3` (no location) for the fragment input.
        try std.testing.expect(std.mem.indexOf(u8, g, "in vec3") != null);
        try std.testing.expect(std.mem.indexOf(u8, g, "layout(location = 0) in vec3") == null);
        // spirv-cross agrees: it also drops the location on the fragment input.
        const sc = try spirvCrossToGlslVersion(alloc, spirv, v, false);
        defer alloc.free(sc);
        try std.testing.expect(std.mem.indexOf(u8, sc, "layout(location = 0) in vec3") == null);
    }

    inline for (.{ 410, 420, 440 }) |v| {
        const g = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = v });
        defer alloc.free(g);
        try std.testing.expect(std.mem.indexOf(u8, g, "layout(location = 0) in vec3") != null);
    }
}

test "glsl-version structural: vertex output location dropped below 410, kept at 410+" {
    const spirv = try compileToSpirvViaGlslang(alloc, attrib_vert_src, .vertex);
    defer alloc.free(spirv);

    // Below 410: vertex INPUT (attribute) keeps location; vertex OUTPUT varying drops
    // it. #169 BLOCKER 1: 400 was previously not dropped.
    inline for (.{ 330, 400 }) |v| {
        const g = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = v });
        defer alloc.free(g);
        try std.testing.expect(std.mem.indexOf(u8, g, "layout(location = 0) in vec3") != null);
        try std.testing.expect(std.mem.indexOf(u8, g, "out vec3") != null);
        try std.testing.expect(std.mem.indexOf(u8, g, "layout(location = 0) out vec3") == null);
    }

    inline for (.{ 410, 420, 440 }) |v| {
        const g = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = v });
        defer alloc.free(g);
        try std.testing.expect(std.mem.indexOf(u8, g, "layout(location = 0) out vec3") != null);
    }
}

// ============================================================================
// #173 (items 1+2): frontend const-array folding gaps
// ============================================================================

/// Run spirv-val on glslpp-produced SPIR-V bytes. Returns true if spirv-val
/// accepts the module (exit 0), false otherwise. spirv-val is the authority on
/// whether the OpTypeArray/OpConstantComposite layout is structurally valid.
/// Skips (error.SkipZigTest) when spirv-val cannot be spawned at all.
fn spirvValAccepts(allocator: std.mem.Allocator, spirv_words: []const u32) !bool {
    const io = compat.testIo();
    const dir = compat.cwd();
    compat.dirMakePath(io, dir, ".zig-cache") catch {};

    const spirv_val = try compat.resolveSpirvVal(allocator);
    defer allocator.free(spirv_val);

    const spirv_bytes = std.mem.sliceAsBytes(spirv_words);
    var tmp_buf: [compat.max_path_bytes]u8 = undefined;
    const spv_path = std.fmt.bufPrint(&tmp_buf, ".zig-cache/val{d}.spv", .{compat.randomInt(u32)}) catch return error.OutOfMemory;
    const f = compat.dirCreateFile(io, dir, spv_path, .{}) catch return error.FileNotFound;
    compat.fileWriteAll(io, f, spirv_bytes) catch {};
    compat.fileClose(io, f);
    defer compat.dirDeleteFile(io, dir, spv_path) catch {};

    const result = compat.processRun(io, allocator, &.{ spirv_val, spv_path }) catch return error.SkipZigTest;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = (result.term.exitedCode() orelse 1) == 0;
    if (!ok) {
        std.debug.print("\nspirv-val REJECTED glslpp output:\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n", .{ result.stdout, result.stderr });
    }
    return ok;
}

test "#173 item2: sized multi-dim const array folds to spirv-val-valid SPIR-V" {
    // `const float m[2][3]` indexed at runtime. Pre-fix the parser wrapped the
    // bracket dims inner-first, so the OpConstantComposite array length did not
    // match its OpTypeArray length → spirv-val "Constituent count does not match
    // NumElements". Post-fix the dims wrap outermost→innermost and it validates.
    const source =
        \\#version 450
        \\layout(location=0) out vec4 FragColor;
        \\void main(){
        \\  const float m[2][3] = float[2][3](float[3](1.0,2.0,3.0), float[3](4.0,5.0,6.0));
        \\  int i = int(gl_FragCoord.x) & 1;
        \\  int j = int(gl_FragCoord.y) % 3;
        \\  FragColor = vec4(m[i][j]);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expect(try spirvValAccepts(alloc, spirv));
}

test "#173 review: mat3x4 const-array fold stays spirv-val-valid when body folds away" {
    // Regression for the dangling-type-id MAJOR. `acc += m[0]` with acc==vec4(0)
    // hits the algebraicSimpl `0.0 + x → x` identity, so the OpStore's stored
    // value becomes an identity-folded id. The Phase-4 rewrite used to treat
    // `words[pos+2]` as a result id for ALL wc>=3 instructions, so it deleted the
    // live OpStore (whose word[pos+2] is the OBJECT operand, not a result),
    // orphaning the matrix/vector type chain → `OpTypeVector %float` with %float
    // DCE'd away → spirv-val "requires a previous definition". mat3x4 (3 vec4
    // columns) was the only case the existing fixtures exercised this shape on.
    const folded =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\layout(location=0) flat in int idx;
        \\const mat3x4 M[2] = mat3x4[2](mat3x4(1.,2.,3.,4.,5.,6.,7.,8.,9.,10.,11.,12.), mat3x4(1.,2.,3.,4.,5.,6.,7.,8.,9.,10.,11.,12.));
        \\void main(){ mat3x4 m = M[idx]; vec4 acc = vec4(0.0); acc += m[0]; o = acc; }
    ;
    const spirv_folded = try glslpp.compileToSPIRV(alloc, folded, .{ .stage = .fragment });
    defer alloc.free(spirv_folded);
    try std.testing.expect(try spirvValAccepts(alloc, spirv_folded));

    // Body-surviving variant: every column contributes so nothing folds away,
    // confirming the const-array fold itself is valid (not just the DCE path).
    const survives =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\layout(location=0) flat in int idx;
        \\const mat3x4 M[2] = mat3x4[2](mat3x4(1.,2.,3.,4.,5.,6.,7.,8.,9.,10.,11.,12.), mat3x4(1.,2.,3.,4.,5.,6.,7.,8.,9.,10.,11.,12.));
        \\void main(){ mat3x4 m = M[idx]; o = m[0] + m[1] + m[2]; }
    ;
    const spirv_survives = try glslpp.compileToSPIRV(alloc, survives, .{ .stage = .fragment });
    defer alloc.free(spirv_survives);
    try std.testing.expect(try spirvValAccepts(alloc, spirv_survives));
}

test "#173 item1: matrix-element const-array global cross-compiles to glslang-valid GLSL" {
    // `const mat4 M[2]` indexed at runtime. Pre-fix the frontend never folded the
    // matrix ctors to constant_composite, so the Private `M` got no initializer
    // and was never declared → the body referenced an undefined `M` (glslang
    // rejects). Post-fix the array folds and `M` is declared with an initializer.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 FragColor;
        \\const mat4 M[2] = mat4[](mat4(1.0), mat4(2.0));
        \\void main(){
        \\  int i = int(gl_FragCoord.x) & 1;
        \\  FragColor = M[i] * vec4(1.0);
        \\}
    ;
    const spirv = try compileToSpirvViaGlslang(alloc, source, .fragment);
    defer alloc.free(spirv);
    const g = try glslpp.spirvToGLSL(alloc, spirv, .{});
    defer alloc.free(g);
    try assertGlslangAccepts(alloc, "matrix-const-array", g, .fragment);
}

// ---------------------------------------------------------------------------
// Loop-header OpPhi lowering: compile via glslpp's OWN pipeline (so the
// loopCounterToPhi pass produces the loop-counter OpPhi), cross-compile to
// GLSL, then assert glslangValidator accepts the result. This validates the
// EMITTED output compiles (catches counter-freeze, stale conditions, and
// duplicate continue-block declarations that SPIR-V-only validation misses).
// ---------------------------------------------------------------------------

fn glslppLoopAccepts(name: []const u8, source: [:0]const u8) !void {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = 450 });
    defer alloc.free(glsl);
    try assertGlslangAccepts(alloc, name, glsl, .fragment);
}

test "loop-phi emitted GLSL compiles: simple for" {
    try glslppLoopAccepts("phi-simple",
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ float x=0.0; for(int i=0;i<20;i++){ x=x+float(i);} o=vec4(x);}
    );
}

test "loop-phi emitted GLSL compiles: nested" {
    try glslppLoopAccepts("phi-nested",
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ float s=0.0; for(int i=0;i<4;i++){ for(int j=0;j<3;j++){ s+=float(i*j);}} o=vec4(s);}
    );
}

test "loop-phi emitted GLSL compiles: early break" {
    try glslppLoopAccepts("phi-break",
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ float s=0.0; for(int i=0;i<100;i++){ s+=float(i); if(s>10.0) break;} o=vec4(s);}
    );
}

test "loop-phi emitted GLSL compiles: continue" {
    try glslppLoopAccepts("phi-continue",
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ float s=0.0; for(int i=0;i<10;i++){ if(i==5) continue; s+=float(i);} o=vec4(s);}
    );
}

test "loop-phi emitted GLSL compiles: empty body (body == continue block)" {
    try glslppLoopAccepts("phi-empty-body",
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ int i; for(i=0;i<10;i++){} o=vec4(float(i));}
    );
}
