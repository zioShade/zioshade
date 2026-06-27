// SPDX-License-Identifier: MIT OR Apache-2.0
//! WGSL backend tests — GLSL → SPIR-V → WGSL pipeline.

const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

const ShaderTest = struct {
    name: [:0]const u8,
    source: [:0]const u8,
};

fn compileToSpirv(name: []const u8, source: [:0]const u8) ![]u32 {
    // Write source to temp file
    const tmp_src = try std.fmt.allocPrint(alloc, "/tmp/wgsl_test_{s}.frag", .{name});
    defer alloc.free(tmp_src);
    const tmp_spv = try std.fmt.allocPrint(alloc, "/tmp/wgsl_test_{s}.spv", .{name});
    defer alloc.free(tmp_spv);

    {
        const src_file = try std.fs.createFileAbsolute(tmp_src, .{});
        defer src_file.close();
        try src_file.writeAll(std.mem.sliceTo(source, 0));
    }

    const glslang = glslpp.compat.resolveVulkanTool(alloc, "glslangValidator") catch return error.SkipZigTest;
    defer alloc.free(glslang);
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ glslang, "-V", tmp_src, "-o", tmp_spv },
    }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    // If glslang rejects the source the `.spv` is never written; skip rather than
    // surface a confusing FileNotFound from the open below (mirrors the exit-code
    // guard in nagaValidateOrSkip).
    if (!(result.term == .Exited and result.term.Exited == 0)) return error.SkipZigTest;

    const spv_file = try std.fs.openFileAbsolute(tmp_spv, .{ .mode = .read_only });
    defer spv_file.close();
    const data = try spv_file.readToEndAlloc(alloc, 1024 * 1024);
    // Convert bytes to u32 words with proper alignment
    const words_len = data.len / 4;
    const words = try alloc.alloc(u32, words_len);
    for (0..words_len) |i| {
        words[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
    }
    alloc.free(data);
    return words;
}

/// Same as compileToSpirv but writes a `.vert` source so glslang compiles it at
/// the VERTEX stage (the extension selects the stage). Produces the EXTERNAL
/// glslang IR shape — notably gl_Position wrapped in a member-decorated
/// `gl_PerVertex` Block — which glslpp's own frontend never emits.
fn compileVertToSpirv(name: []const u8, source: [:0]const u8) ![]u32 {
    const tmp_src = try std.fmt.allocPrint(alloc, "/tmp/wgsl_test_{s}.vert", .{name});
    defer alloc.free(tmp_src);
    const tmp_spv = try std.fmt.allocPrint(alloc, "/tmp/wgsl_test_{s}_vert.spv", .{name});
    defer alloc.free(tmp_spv);

    {
        const src_file = try std.fs.createFileAbsolute(tmp_src, .{});
        defer src_file.close();
        try src_file.writeAll(std.mem.sliceTo(source, 0));
    }

    const glslang = glslpp.compat.resolveVulkanTool(alloc, "glslangValidator") catch return error.SkipZigTest;
    defer alloc.free(glslang);
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ glslang, "-V", tmp_src, "-o", tmp_spv },
    }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    // If glslang rejects the source the `.spv` is never written; skip rather than
    // surface a confusing FileNotFound from the open below (mirrors the exit-code
    // guard in nagaValidateOrSkip).
    if (!(result.term == .Exited and result.term.Exited == 0)) return error.SkipZigTest;

    const spv_file = try std.fs.openFileAbsolute(tmp_spv, .{ .mode = .read_only });
    defer spv_file.close();
    const data = try spv_file.readToEndAlloc(alloc, 1024 * 1024);
    const words_len = data.len / 4;
    const words = try alloc.alloc(u32, words_len);
    for (0..words_len) |i| {
        words[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
    }
    alloc.free(data);
    return words;
}

fn assertNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle)) |_| {
        std.debug.print("Did NOT expect to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedFind;
    }
}

fn assertContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Expected to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedFind;
    }
}

/// Count instructions with the given SPIR-V opcode in a word stream (skips the
/// 5-word header). Used for IR-level regression guards that don't depend on a
/// particular backend's text emission.
fn countSpirvOpcode(words: []const u32, opcode: u16) u32 {
    var count: u32 = 0;
    var pos: usize = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        if (wc == 0) break;
        if (@as(u16, @truncate(words[pos] & 0xFFFF)) == opcode) count += 1;
        pos += wc;
    }
    return count;
}

/// Build a malformed copy of `words` where the FIRST instruction with the given
/// opcode has its trailing operand word removed (and its word-count header
/// decremented to match, so the rest of the stream still parses). Used to
/// synthesize truncated SPIR-V: an image instruction whose mask still claims a
/// ConstOffset operand but whose offset <id> word is missing. No conformant
/// producer emits this, but the backend must reject it loudly rather than
/// silently drop the claimed offset. Caller frees the result.
fn truncateLastOperand(words: []const u32, opcode: u16) ![]u32 {
    var pos: usize = 5;
    while (pos < words.len) {
        const wc: usize = words[pos] >> 16;
        if (wc == 0) break;
        if (@as(u16, @truncate(words[pos] & 0xFFFF)) == opcode) {
            const drop_idx = pos + wc - 1; // index of the trailing operand word
            const out = try alloc.alloc(u32, words.len - 1);
            @memcpy(out[0..drop_idx], words[0..drop_idx]);
            @memcpy(out[drop_idx..], words[drop_idx + 1 ..]);
            out[pos] = (@as(u32, @intCast(wc - 1)) << 16) | @as(u32, opcode);
            return out;
        }
        pos += wc;
    }
    return error.OpcodeNotFound;
}

/// Return a copy of `words` whose FIRST instruction with opcode `from_op` has its
/// opcode rewritten to `to_op` (same word count, operands untouched). glslpp's
/// frontend always lowers GLSL `>>` to OpShiftRightLogical even for signed
/// operands (codegen.zig), so OpShiftRightArithmetic never appears in its own
/// output — the only way to reach the backend's arithmetic-shift arm is hand-fed
/// or external SPIR-V (e.g. spirv-cross's bitcast_sar fixture). This rewrite
/// synthesizes that input from a logical shift. Caller frees the result.
fn rewriteFirstOpcode(words: []const u32, from_op: u16, to_op: u16) ![]u32 {
    var pos: usize = 5;
    while (pos < words.len) {
        const wc: usize = words[pos] >> 16;
        if (wc == 0) break;
        if (@as(u16, @truncate(words[pos] & 0xFFFF)) == from_op) {
            const out = try alloc.dupe(u32, words);
            out[pos] = (@as(u32, @intCast(wc)) << 16) | @as(u32, to_op);
            return out;
        }
        pos += wc;
    }
    return error.OpcodeNotFound;
}

// Validate WGSL with naga — the external WebGPU validator. The whole point of
// the "silent-wrong" class of bugs is that glslpp emits text that LOOKS fine
// (exit 0) but a real validator rejects, so string assertions alone can pass
// while the output is still invalid. naga is the ground truth. When naga isn't
// installed we SKIP rather than fail, keeping `zig build test` hermetic.
fn nagaValidateOrSkip(wgsl: []const u8, label: []const u8) !void {
    const probe = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "naga", "--version" },
    }) catch return error.SkipZigTest;
    alloc.free(probe.stdout);
    alloc.free(probe.stderr);
    if (!(probe.term == .Exited and probe.term.Exited == 0)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "out.wgsl", .data = wgsl });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath("out.wgsl", &path_buf);

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "naga", "--input-kind", "wgsl", tmp_path },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term == .Exited and result.term.Exited == 0) return;
    std.debug.print("naga REJECTED WGSL for [{s}]:\n{s}\n{s}\n--- WGSL ---\n{s}\n", .{ label, result.stdout, result.stderr, wgsl });
    return error.NagaValidationFailed;
}

/// Compile GLSL → SPIR-V → WGSL via glslpp's own frontend (mirrors the MSL/HLSL
/// test helpers). Caller frees the result.
fn compileToWgsl(source: [:0]const u8) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try glslpp.spirvToWGSL(alloc, spirv, .{});
}

fn compileVertToWgsl(source: [:0]const u8) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    return try glslpp.spirvToWGSL(alloc, spirv, .{});
}

fn compileCompToWgsl(source: [:0]const u8) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spirv);
    return try glslpp.spirvToWGSL(alloc, spirv, .{});
}

/// Compile a GLSL fixture FILE (relative to the repo root) → WGSL via glslpp's
/// frontend. Used for cases whose cross-function structure glslpp's inliner
/// collapses for small inline shaders — the real fixture preserves the helper.
fn compileFileToWgsl(path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const src = try file.readToEndAllocOptions(alloc, 1 << 20, null, .of(u8), 0);
    defer alloc.free(src);
    return compileToWgsl(src);
}

/// Same as compileFileToWgsl but compiles at the VERTEX stage (for `.vert` fixtures).
fn compileFileVertToWgsl(path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const src = try file.readToEndAllocOptions(alloc, 1 << 20, null, .of(u8), 0);
    defer alloc.free(src);
    return compileVertToWgsl(src);
}

/// True if the SPIR-V module carries any `OpDecorate <target> <decoration>`
/// (opcode 71) with the given decoration value. Word layout: [0]=magic,
/// [1]=version, [2]=generator, [3]=bound, [4]=schema, then instructions; each
/// instruction's first word is (wordCount << 16) | opcode and OpDecorate's
/// operands are [target, decoration, ...]. `compileToSPIRV` yields []const u32,
/// so words are indexed directly.
fn spirvHasDecoration(words: []const u32, decoration: u32) bool {
    if (words.len < 5) return false;
    var i: usize = 5;
    while (i < words.len) {
        const wc = words[i] >> 16;
        const op = words[i] & 0xFFFF;
        if (wc == 0) break;
        if (op == 71 and i + 2 < words.len and words[i + 2] == decoration) return true;
        i += wc;
    }
    return false;
}

fn runWgslTest(test_case: ShaderTest) !void {
    const spirv = compileToSpirv(test_case.name, test_case.source) catch |err| {
        std.debug.print("FAIL [{s}]: glslang failed: {}\n", .{ test_case.name, err });
        return err;
    };
    defer alloc.free(spirv);

    const wgsl = glslpp.spirvToWGSL(alloc, spirv, .{}) catch |err| {
        std.debug.print("FAIL [{s}]: spirvToWGSL failed: {}\n", .{ test_case.name, err });
        return err;
    };
    defer alloc.free(wgsl);

    if (wgsl.len == 0) {
        std.debug.print("FAIL [{s}]: WGSL output is empty\n", .{test_case.name});
        return error.TestEmptyOutput;
    }

    try assertNotContains(wgsl, "unhandled op");
}

test "wgsl basic color output" {
    try runWgslTest(.{
        .name = "basic",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    fragColor = vec4(1.0, 0.0, 0.0, 1.0);
        \\}
        ,
    });
}

test "wgsl arithmetic" {
    try runWgslTest(.{
        .name = "arithmetic",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float a = 1.0 + 2.0;
        \\    float b = a * 3.0;
        \\    fragColor = vec4(b, b, b, 1.0);
        \\}
        ,
    });
}

test "wgsl builtin functions" {
    try runWgslTest(.{
        .name = "builtins",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float x = sin(0.5);
        \\    float y = cos(0.5);
        \\    float z = sqrt(x * x + y * y);
        \\    fragColor = vec4(x, y, z, 1.0);
        \\}
        ,
    });
}

test "wgsl struct access" {
    try runWgslTest(.{
        .name = "struct_access",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\struct Foo { float a; float b; };
        \\void main() {
        \\    Foo f;
        \\    f.a = 1.0;
        \\    f.b = 2.0;
        \\    fragColor = vec4(f.a, f.b, 0.0, 1.0);
        \\}
        ,
    });
}

test "wgsl control flow" {
    try runWgslTest(.{
        .name = "control_flow",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float x = 0.0;
        \\    if (x > 0.5) {
        \\        x = 1.0;
        \\    } else {
        \\        x = 0.0;
        \\    }
        \\    fragColor = vec4(x, 0.0, 0.0, 1.0);
        \\}
        ,
    });
}

test "wgsl vector operations" {
    try runWgslTest(.{
        .name = "vector_ops",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 a = vec3(1.0, 2.0, 3.0);
        \\    vec3 b = vec3(4.0, 5.0, 6.0);
        \\    float d = dot(a, b);
        \\    vec3 n = normalize(a);
        \\    fragColor = vec4(n, d);
        \\}
        ,
    });
}

test "wgsl mix and clamp" {
    try runWgslTest(.{
        .name = "mix_clamp",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float x = mix(0.0, 1.0, 0.5);
        \\    float y = clamp(x, 0.0, 0.8);
        \\    fragColor = vec4(x, y, 0.0, 1.0);
        \\}
        ,
    });
}

test "wgsl type conversions" {
    try runWgslTest(.{
        .name = "conversions",
        .source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int i = 42;
        \\    float f = float(i);
        \\    uint u = uint(f);
        \\    fragColor = vec4(float(i), f, float(u), 1.0);
        \\}
        ,
    });
}

// An unmapped GLSL.std.450 extended instruction (interpolateAtCentroid →
// glslpp opcode 76) must make the WGSL backend FAIL LOUDLY, not silently emit
// invalid `unknown(...)` text. interpolateAt* are frontend-supported but
// unmapped in the WGSL ext-inst dispatch, so they exercise the fallback path.
//
// Compiled through glslpp's own frontend (not glslang) so the internal
// GLSL.std.450 numbering (76/77/78) is what reaches spirvToWGSL.
test "wgsl unmapped ext-inst errors honestly instead of emitting unknown()" {
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_ARB_gpu_shader5 : enable
        \\layout(location = 0) in vec2 vUv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 c = interpolateAtCentroid(vUv);
        \\    fragColor = vec4(c, 0.0, 1.0);
        \\}
    ;

    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    try std.testing.expectError(
        error.UnsupportedExtInst,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );
}

// WGSL has no isInf builtin (and no infinity literal). isinf(x) lowers to the
// literal-free idiom (x != 0.0 && x * 2.0 == x), which is true ONLY for ±inf:
// 0 is excluded by `x != 0.0`; a finite nonzero x has `x*2 != x`; NaN fails the
// `==`; the max finite value overflows under `*2.0` to inf, which `!= x`. Must
// be naga-validated WGSL with no `isInf`/`isinf` identifier leak. (#170)
test "wgsl scalar isinf lowers to a naga-valid idiom (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float v;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    bool b = isinf(v);
        \\    fragColor = vec4(b ? 1.0 : 0.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The non-existent WGSL builtin must never leak (naga: undefined identifier).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "isInf") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "isinf") == null);
    // Positively lock the idiom shape so a future refactor can't swap in a
    // different (still naga-valid) but incorrect expression.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "* 2.0 ==") != null);
    try nagaValidateOrSkip(wgsl, "scalar-isinf");
}

// WGSL has no inf/nan float literal. A non-finite float CONSTANT (e.g. an
// overflowing `1e40` literal folded to +inf) was previously emitted as the bare
// `inf`/`nan` identifier (naga: "no definition in scope for identifier: `inf`").
// It must instead be emitted as `bitcast<f32>(0x..u)` from the exact bit pattern. (#252)
test "wgsl non-finite float constant emits bitcast, not bare inf/nan (#252)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float big = 1e40; // overflows f32 -> +inf constant
        \\    fragColor = vec4(big, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "bitcast<f32>(0x") != null);
    // The bare non-finite identifiers must never leak.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "inf") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "nan") == null);
    try nagaValidateOrSkip(wgsl, "nonfinite-const");
}

// #252: a non-finite float has NO valid WGSL const-expression form — `bitcast`
// (used for runtime contexts) is itself rejected by naga inside a const/override
// initializer ("Not implemented as constant expression: bitcast"). So a non-finite
// float in a module-scope `const` initializer, or as a spec-constant (`override`)
// default, is unrepresentable and must fail loud rather than emit naga-invalid output.
test "wgsl non-finite float in a const-global initializer is an honest error (#252)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) flat in int idx;
        \\layout(location = 0) out vec4 fragColor;
        \\const vec4 LUT[2] = vec4[2](vec4(1e40, 0.0, 0.0, 1.0), vec4(1.0));
        \\void main() { fragColor = LUT[idx]; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl non-finite spec-constant (override) default is an honest error (#252)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(constant_id = 0) const float K = 1e40;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(K, 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: atomicCompSwap(mem, compare, data) → WGSL atomicCompareExchangeWeak(ptr,
// compare, new). OpAtomicCompareExchange has TWO memory-semantics operands
// (Equal + Unequal), so its layout is [ptr][scope][eq-sem][uneq-sem][value(new)]
// [comparator(compare)]. The backend read the COMPARE arg from the unequal-semantics
// word instead of the comparator word — emitting the memory-semantics constant (64)
// as the compare value: silent-wrong (naga accepts it, the value is just wrong).
test "wgsl atomicCompSwap uses the comparator, not a memory-semantics operand (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { uint lock; uint out_old; } b;
        \\void main() {
        \\    uint old = atomicCompSwap(b.lock, 7u, 9u); // compare 7, set 9
        \\    b.out_old = old;
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .compute, .spirv_version = .@"1.5" });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Must compare against 7 and store 9 — `atomicCompareExchangeWeak(&ptr, 7u, 9u)`.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "atomicCompareExchangeWeak(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "7u, 9u).old_value") != null);
    try nagaValidateOrSkip(wgsl, "atomic-compswap");
}

// #170: atomicExchange(mem, data) → WGSL atomicExchange(ptr, data). OpAtomicExchange's
// operand layout is [ptr][scope][semantics][value], so the new value is words[6]. The
// inline emitter read words[4] (the SCOPE) as the value — emitting the scope constant
// instead of the data: silent-wrong (naga accepts it, the stored value is wrong).
test "wgsl atomicExchange stores the value operand, not the scope (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { uint slot; uint out_old; } b;
        \\void main() {
        \\    uint old = atomicExchange(b.slot, 42u); // store 42
        \\    b.out_old = old;
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .compute, .spirv_version = .@"1.5" });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "atomicExchange(&b.slot, 42u)") != null);
    try nagaValidateOrSkip(wgsl, "atomic-exchange");
}

// #170: the atomic binary ops (atomicAdd/Sub/And/Or/Xor/Min/Max) read their value
// operand from words[6] — words[4] is the memory SCOPE and words[5] the semantics.
// The emitter read words[4], so every atomic op emitted the scope constant (Device == 1)
// as its value: `atomicAdd(b.total, 37u)` became `atomicAdd(&b.total, 1u)`. Masked
// because atomic counters often add 1u (== the scope), and naga accepts either.
test "wgsl atomic binary op uses the value operand, not the scope (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { uint total; } b;
        \\void main() {
        \\    atomicAdd(b.total, 37u); // add 37, NOT the scope constant 1
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .compute, .spirv_version = .@"1.5" });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "atomicAdd(&b.total, 37u)") != null);
    try nagaValidateOrSkip(wgsl, "atomic-add-value");
}

// #258: the same guard must cover the unsigned-division (OpUDiv) and modulo (`%`)
// operator paths — `4u / 0u` and `4 % 0` are equally const-rejected by naga.
test "wgsl constant unsigned division by zero is an honest error (#258)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    uint a = 4u / 0u;
        \\    fragColor = vec4(float(a), 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl constant integer modulo by zero is an honest error (#258)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int a = 4 % 0;
        \\    fragColor = vec4(float(a), 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #254 (follow-up to #252): the frontend does NOT fold a constant division by zero,
// so `1.0/0.0` reaches the WGSL backend as an OpFDiv of two constants and was emitted
// as the literal division `1.0f / 0.0f` — which naga const-evaluates and rejects
// ("Float literal is infinite"). The backend must const-fold a non-finite float
// arithmetic result (here +inf) into `bitcast<f32>(0x..u)` (a runtime value naga
// accepts), in function-body / runtime context.
test "wgsl constant division by zero folds to a bitcast, not a literal division (#254)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float a = 1.0/0.0; // +inf — frontend does not fold this
        \\    fragColor = vec4(a, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // +inf has bit pattern 0x7f800000.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "bitcast<f32>(0x7f800000") != null);
    // No naga-rejected literal division-by-zero must survive.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "/ 0.0f") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "inf") == null);
    try nagaValidateOrSkip(wgsl, "const-div-by-zero");
}

// 0.0/0.0 is NaN (e.g. 0x7fc00000 on x86-64; the NaN payload is platform-defined, so
// the test pins only the bitcast prefix). It must also fold to a bitcast rather than a
// naga-rejected literal.
test "wgsl constant 0/0 folds to a NaN bitcast (#254)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float a = 0.0/0.0; // NaN
        \\    fragColor = vec4(a, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "bitcast<f32>(0x") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "/ 0.0f") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "nan") == null);
    try nagaValidateOrSkip(wgsl, "const-nan-div");
}

// #254: the same non-finite-constant-arithmetic hazard reaches the `%` operator —
// `mod(1.0, 0.0)` is an OpFMod of two constants emitted as `1.0f % 0.0f`, which naga
// const-evaluates to NaN and rejects ("Float literal is NaN"). It must fold to a
// bitcast too (caught by the review of the division fix).
test "wgsl constant mod by zero folds to a NaN bitcast (#254)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float a = mod(1.0, 0.0); // NaN
        \\    fragColor = vec4(a, 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "bitcast<f32>(0x") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "% 0.0f") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "nan") == null);
    try nagaValidateOrSkip(wgsl, "const-mod-by-zero");
}

// #258: a pre-existing emitBinOp band-aid emitted `let v: T = 0.0;` for ANY division
// whose divisor renders as a literal zero. Integer constants render as bare "0", so an
// INTEGER division by a literal zero hit it — producing `let v: i32 = 0.0;`, which naga
// rejects as a type error ("expected i32, got AbstractFloat"). A RUNTIME integer
// divide-by-zero is well-defined in WGSL (x / 0 == x) and naga accepts the raw `b / 0`,
// so it must be emitted as a normal division, not the type-wrong `0.0`.
test "wgsl runtime integer division by zero emits a valid division, not 0.0 (#258)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) flat in int b;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int a = b / 0; // runtime dividend; WGSL defines x/0 == x
        \\    fragColor = vec4(float(a), 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The type-wrong band-aid output must be gone.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ": i32 = 0.0;") == null);
    try nagaValidateOrSkip(wgsl, "runtime-int-div-zero");
}

// #258: an INTEGER CONSTANT divided by a constant zero (`4 / 0`) is genuinely
// unrepresentable — naga const-evaluates it and rejects ("Division by zero"), and WGSL
// has no integer inf/nan. (The float analogue is folded to a bitcast by #254; that path
// runs before this one.) It must fail loud rather than emit the old naga-invalid `0.0`.
test "wgsl constant integer division by zero is an honest error (#258)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int a = 4 / 0; // const/const integer div-by-zero — unrepresentable in WGSL
        \\    fragColor = vec4(float(a), 0.0, 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// WGSL has no matrix-inverse builtin. GLSL inverse() (GLSL.std.450 MatrixInverse)
// must NOT silently emit `matrixInverse(m)` (naga: "no definition in scope").
// Pass 2 lowers it to an emit-once generated `spvInverseN` helper (cofactor /
// determinant inverse), so the result must now be naga-validated WGSL that both
// declares the helper and calls it. Covers mat4/mat3/mat2.
test "wgsl inverse(mat4) lowers to spvInverse4 helper (naga-validated)" {
    // Build the matrix from vertex inputs (not a UBO) so this targets only the
    // MatrixInverse path. (A separate pre-existing struct-name error-path leak in
    // spirvToWGSL is tracked as a follow-up.)
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 c0;
        \\layout(location = 1) in vec4 c1;
        \\layout(location = 2) in vec4 c2;
        \\layout(location = 3) in vec4 c3;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    mat4 m = mat4(c0, c1, c2, c3);
        \\    fragColor = inverse(m) * vec4(1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "fn spvInverse4(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "spvInverse4(") != null);
    // The unmapped GLSL spelling must NEVER leak.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "matrixInverse") == null);
    try nagaValidateOrSkip(wgsl, "inverse-mat4");
}

test "wgsl inverse(mat3) lowers to spvInverse3 helper (naga-validated)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec3 c0;
        \\layout(location = 1) in vec3 c1;
        \\layout(location = 2) in vec3 c2;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    mat3 m = mat3(c0, c1, c2);
        \\    fragColor = vec4(inverse(m) * vec3(1.0), 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "fn spvInverse3(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "spvInverse3(") != null);
    try nagaValidateOrSkip(wgsl, "inverse-mat3");
}

test "wgsl inverse(mat2) lowers to spvInverse2 helper (naga-validated)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 c0;
        \\layout(location = 1) in vec2 c1;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    mat2 m = mat2(c0, c1);
        \\    fragColor = vec4(inverse(m) * vec2(1.0), 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "fn spvInverse2(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "spvInverse2(") != null);
    try nagaValidateOrSkip(wgsl, "inverse-mat2");
}

// textureGatherOffsets lowers (correctly, for the SPIR-V target) to
// OpImageGather carrying the ConstOffsets image operand — a per-texel
// 4-offset array. WGSL's `textureGather` cannot take a 4-offset array, so the
// WGSL backend must FAIL LOUDLY rather than silently emit a plain
// `textureGather` that drops the offsets. ImageGather IS otherwise mapped in
// WGSL, so it needs a specific ConstOffsets guard (the unmapped-op path does
// not cover it). NOTE: glslpp's OWN frontend DOES compile `textureGatherOffsets`
// (the 4-offset form, via the .image_gather_offsets IR tag → ConstOffsets 0x20),
// so this test uses the internal compileToSPIRV path — unlike the single-offset
// `textureGatherOffset` below, which the frontend rejects and must be compiled
// through glslang.
test "wgsl: textureGatherOffsets (ConstOffsets) is an honest error, not a silent plain gather" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  const ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
        \\  o = textureGatherOffsets(s, vec2(0.5), offs, 1);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    try std.testing.expectError(
        error.UnsupportedImageOperands,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );
}

// textureGatherOffset (a SINGLE ConstOffset image operand, mask bit 0x8) lowers
// to OpImageGather carrying a constant `vec2<i32>` offset. Unlike the 4-offset
// ConstOffsets form, WGSL's `textureGather` DOES take a trailing const-offset
// argument — `textureGather(component, t, s, coords, offset)` — so the offset
// must be emitted. Dropping it (the previous behavior) silently gathers the
// WRONG texels (silent-wrong): the call type-checks and naga accepts it, but the
// sampled neighborhood is shifted. glslpp's frontend now compiles
// `textureGatherOffset` directly (the builtin is registered and lowered to
// OpImageGather + ConstOffset), so this exercises the FULL glslpp pipeline
// frontend→WGSL end-to-end. (#170)
test "wgsl: textureGatherOffset (single ConstOffset) keeps the offset, not a silent plain gather" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  o = textureGatherOffset(s, vec2(0.5), ivec2(3, 4), 1);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);

    // The offset must reach the textureGather call as a trailing 5th argument
    // (the gather without offset ends `...vec2<f32>(0.5))`; with it, a `, ` and
    // the offset constant follow). Asserting the prefix proves the offset arg
    // exists; the value check proves the actual (3,4) offset survived.
    try assertContains(wgsl, "textureGather(1, s, s_sampler, vec2<f32>(0.5), ");
    try assertContains(wgsl, "(3, 4)");
    // naga is the ground truth: confirms the offset's type/position is valid.
    try nagaValidateOrSkip(wgsl, "gather-offset");
}

// textureGatherOffset on an ARRAYED sampler: WGSL takes the const-offset as the
// LAST argument, AFTER the separate rounded i32 array_index —
// textureGather(component, t, s, coords.xy, i32(round(coords.z)), offset).
// Emitting the offset before the array_index (or dropping it) is silent-wrong;
// only naga catches the ordering. Guards the arrayed emit branch of the fix.
test "wgsl: textureGatherOffset on sampler2DArray keeps offset after array_index" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray s;
        \\layout(location=0) in vec3 vUV;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  o = textureGatherOffset(s, vUV, ivec2(3, 4), 1);
        \\}
    ;
    // glslpp's frontend now compiles textureGatherOffset directly (full pipeline).
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);

    // array_index (i32(round(vUV.z))) precedes the trailing offset.
    try assertContains(wgsl, "i32(round(vUV.z)), vec2<i32>(3, 4))");
    try nagaValidateOrSkip(wgsl, "gather-offset-array");
}

// A *dynamic* (non-constant) gather offset compiles (with GL_ARB_gpu_shader5) to
// OpImageGather carrying the runtime `Offset` image operand (mask bit 0x10), NOT
// the constant ConstOffset (0x8). WGSL's textureGather offset argument must be a
// const-expression, so a runtime offset has NO faithful mapping — it must FAIL
// LOUDLY rather than silently drop the offset (which gathers the wrong texels,
// exactly the bug the ConstOffset lowering fixes). Guards the generalized
// "any operand except ConstOffset is unsupported" check.
test "wgsl: textureGatherOffset with a runtime (non-const) offset is an honest error" {
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_ARB_gpu_shader5 : enable
        \\layout(binding=0) uniform sampler2D s;
        \\layout(location=0) flat in int idx;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  o = textureGatherOffset(s, vec2(0.5), ivec2(idx, 0), 1);
        \\}
    ;
    const spirv = compileToSpirv("gather_offset_dyn", source) catch return error.SkipZigTest;
    defer alloc.free(spirv);

    try std.testing.expectError(
        error.UnsupportedImageOperands,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );
}

// A GLSL `sampler2DShadow` lowers to an OpTypeImage with the Depth operand set
// (word[4] == 1). WGSL's `textureGatherCompare` / `textureSampleCompare`
// builtins REQUIRE a `texture_depth_2d` texture paired with a
// `sampler_comparison` sampler. The backend defaulted every texture to
// `texture_2d<f32>` + plain `sampler`, producing WGSL that glslpp emits without
// error (exit 0) but that naga REJECTS:
//
//   "Comparison sampling mismatch: image has class Sampled { kind: Float, ... },
//    but the sampler is comparison=false, and the reference was provided=true"
//
// That is a silent-wrong cross-compile. The resource TYPES must follow the
// depth/comparison nature of the image.
test "wgsl: sampler2DShadow gather emits texture_depth_2d + sampler_comparison" {
    try runShadowValidTest(.{
        .name = "shadow_gather",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow shadowTex;
        \\layout(location=0) in vec2 vUV;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureGather(shadowTex, vUV, vRef); }
        ,
        .tex_decl = "var shadowTex: texture_depth_2d;",
        .builtin = "textureGatherCompare",
        // gather keeps the coordinate (vUV) and reference separate — no slice.
        .coord_swizzle = null,
    });
}

test "wgsl: sampler2DShadow compare-sample emits texture_depth_2d + sampler_comparison" {
    try runShadowValidTest(.{
        .name = "shadow_sample",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow shadowTex;
        \\layout(location=0) in vec2 vUV;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowTex, vec3(vUV, vRef))); }
        ,
        .tex_decl = "var shadowTex: texture_depth_2d;",
        .builtin = "textureSampleCompare",
        // glslang packs the ref into the coordinate (vec3); it must be sliced
        // to vec2. This `.xy` guard catches the coordinate-dimension bug even
        // when naga is unavailable (string assertions alone would not).
        .coord_swizzle = ".xy",
    });
}

// samplerCubeShadow → texture_depth_cube; the packed vec4(dir, ref) coordinate
// must be sliced to the 3-component cube coordinate (.xyz).
test "wgsl: samplerCubeShadow emits texture_depth_cube + sampler_comparison" {
    try runShadowValidTest(.{
        .name = "shadow_cube",
        .source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeShadow shadowCube;
        \\layout(location=0) in vec3 vDir;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowCube, vec4(vDir, vRef))); }
        ,
        .tex_decl = "var shadowCube: texture_depth_cube;",
        .builtin = "textureSampleCompare",
        .coord_swizzle = ".xyz",
    });
}

// textureLod on a shadow sampler lowers to OpImageSampleDrefExplicitLod →
// textureSampleCompareLevel, which (a) needs the same coordinate slice and
// (b) takes NO explicit level argument (it always samples mip 0). Emitting the
// raw coordinate + a trailing float level is rejected by naga.
test "wgsl: textureLod(sampler2DShadow) emits valid textureSampleCompareLevel" {
    try runShadowValidTest(.{
        .name = "shadow_lod",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow shadowTex;
        \\layout(location=0) in vec2 vUV;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(textureLod(shadowTex, vec3(vUV, vRef), 0.0)); }
        ,
        .tex_decl = "var shadowTex: texture_depth_2d;",
        .builtin = "textureSampleCompareLevel",
        .coord_swizzle = ".xy",
    });
}

// Arrayed depth textures (sampler2DArrayShadow) need a SEPARATE WGSL array_index
// argument: textureSampleCompare(t, s, coord.xy, array_index, depth_ref). glslang
// packs the layer into the coordinate (vec4: uv, layer, ref); the layer component
// must be extracted, rounded, and passed as its own i32 argument. Emitting
// texture_depth_2d + a 2-component coordinate (dropping the layer) VALIDATES in
// naga but silently samples the wrong layer — the very silent-wrong this guards.
test "wgsl: sampler2DArrayShadow emits texture_depth_2d_array + separate array_index" {
    try runShadowValidTest(.{
        .name = "shadow_2d_array",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArrayShadow shadowArr;
        \\layout(location=0) in vec4 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowArr, vC)); }
        ,
        .tex_decl = "var shadowArr: texture_depth_2d_array;",
        .builtin = "textureSampleCompare",
        // 2D spatial coordinate is .xy; the layer (.z) becomes a separate arg.
        .coord_swizzle = ".xy",
        .array_index = ".z))",
    });
}

// samplerCubeArrayShadow → texture_depth_cube_array. The coordinate is a vec4
// (dir.xyz + layer.w); the direction is sliced to vec3 and the layer (.w) becomes
// a separate rounded i32 array_index argument. The compare reference is a
// separate GLSL argument, so it is NOT packed into the coordinate here.
test "wgsl: samplerCubeArrayShadow emits texture_depth_cube_array + separate array_index" {
    try runShadowValidTest(.{
        .name = "shadow_cube_array",
        .source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeArrayShadow shadowCubeArr;
        \\layout(location=0) in vec4 vC;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(texture(shadowCubeArr, vC, vRef)); }
        ,
        .tex_decl = "var shadowCubeArr: texture_depth_cube_array;",
        .builtin = "textureSampleCompare",
        // Cube spatial coordinate is .xyz; the layer (.w) becomes a separate arg.
        .coord_swizzle = ".xyz",
        .array_index = ".w))",
    });
}

// textureLod on an arrayed shadow sampler lowers to OpImageSampleDrefExplicitLod
// → textureSampleCompareLevel, exercising the OTHER branch of emitDepthCompare:
// the array layer must STILL be split out as a separate i32 array_index (and the
// SPIR-V Lod operand dropped — WGSL's compare-level builtin always samples mip 0).
// Requires GL_EXT_texture_shadow_lod for textureLod() on a shadow sampler.
test "wgsl: textureLod(sampler2DArrayShadow) emits textureSampleCompareLevel + array_index" {
    try runShadowValidTest(.{
        .name = "shadow_2d_array_lod",
        .source =
        \\#version 450
        \\#extension GL_EXT_texture_shadow_lod : require
        \\layout(binding=0) uniform sampler2DArrayShadow shadowArr;
        \\layout(location=0) in vec4 vC;
        \\layout(location=1) in float vLod;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = vec4(textureLod(shadowArr, vC, vLod)); }
        ,
        .tex_decl = "var shadowArr: texture_depth_2d_array;",
        .builtin = "textureSampleCompareLevel",
        .coord_swizzle = ".xy",
        .array_index = ".z))",
    });
}

// textureGatherCompare on an ARRAYED shadow sampler needs a separate array_index
// argument, just like the compare-SAMPLE path: WGSL's
// textureGatherCompare(t: texture_depth_2d_array, s, coords: vec2, array_index, depth_ref).
// glslang packs the layer into the coordinate (vec3: uv, layer) with the compare
// ref as a separate GLSL arg; the layer (.z) must be sliced out, rounded, and
// passed as its own i32 argument. Previously honest-errored (#170); now wired
// (#170, naga-gated) so the GLSL gather faithfully lowers instead of being rejected.
test "wgsl: textureGather(sampler2DArrayShadow) emits textureGatherCompare + array_index" {
    try runShadowValidTest(.{
        .name = "shadow_gather_2d_array",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArrayShadow shadowArr;
        \\layout(location=0) in vec3 vC;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureGather(shadowArr, vC, vRef); }
        ,
        .tex_decl = "var shadowArr: texture_depth_2d_array;",
        .builtin = "textureGatherCompare",
        // 2D spatial coordinate is .xy; the layer (.z) becomes a separate arg.
        .coord_swizzle = ".xy",
        .array_index = ".z))",
    });
}

// samplerCubeArrayShadow gather → texture_depth_cube_array: the vec4 coordinate
// (dir.xyz + layer.w) is sliced to the vec3 direction and the layer (.w) becomes
// a separate rounded i32 array_index argument. Compare ref is a separate GLSL arg.
test "wgsl: textureGather(samplerCubeArrayShadow) emits textureGatherCompare + array_index" {
    try runShadowValidTest(.{
        .name = "shadow_gather_cube_array",
        .source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeArrayShadow shadowCubeArr;
        \\layout(location=0) in vec4 vC;
        \\layout(location=1) in float vRef;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureGather(shadowCubeArr, vC, vRef); }
        ,
        .tex_decl = "var shadowCubeArr: texture_depth_cube_array;",
        .builtin = "textureGatherCompare",
        // Cube spatial coordinate is .xyz; the layer (.w) becomes a separate arg.
        .coord_swizzle = ".xyz",
        .array_index = ".w))",
    });
}

const ShadowCase = struct {
    name: []const u8,
    source: [:0]const u8,
    tex_decl: []const u8,
    builtin: []const u8,
    /// Expected coordinate swizzle proving the packed coordinate was sliced to
    /// the texture dimension; null when the form keeps the coordinate as-is
    /// (e.g. gather). A naga-independent regression guard.
    coord_swizzle: ?[]const u8,
    /// For arrayed depth textures, the distinguishing tail of the SEPARATE
    /// array_index argument (e.g. ".z))" for texture_depth_2d_array, ".w))" for
    /// texture_depth_cube_array). null for non-arrayed forms. Proves the array
    /// layer was preserved as its own integer argument rather than silently
    /// folded into the coordinate or dropped.
    array_index: ?[]const u8 = null,
};

fn runShadowValidTest(c: ShadowCase) !void {
    const spirv = try compileToSpirv(c.name, c.source);
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);

    // The depth texture must be emitted with its exact comparison type (the
    // exact decl also rules out the silent-wrong `texture_2d<f32>` for it)...
    try assertContains(wgsl, c.tex_decl);
    // ...the companion sampler must be a comparison sampler...
    try assertContains(wgsl, "sampler_comparison");
    // ...the compare builtin must still be emitted (regression guard). Match the
    // trailing "(" so "textureSampleCompare" does not spuriously satisfy a case
    // that actually emitted "textureSampleCompareLevel" (the former is a prefix
    // of the latter), and vice versa...
    const builtin_call = try std.fmt.allocPrint(alloc, "{s}(", .{c.builtin});
    defer alloc.free(builtin_call);
    try assertContains(wgsl, builtin_call);
    // ...the coordinate must be sliced to the texture dimension (naga-free guard)...
    if (c.coord_swizzle) |swz| try assertContains(wgsl, swz);
    // ...an arrayed depth texture must pass the layer as its own rounded i32
    // array_index argument (naga-free guard against the dropped-layer bug)...
    if (c.array_index) |ai| {
        try assertContains(wgsl, "i32(round(");
        try assertContains(wgsl, ai);
    }
    // ...and (single-texture fixture) no plain sampled texture must appear.
    try assertNotContains(wgsl, "texture_2d<f32>");
    // Ground truth: the emitted WGSL must actually validate.
    try nagaValidateOrSkip(wgsl, c.name);
}

// Projective depth-compare: `textureProj(sampler2DShadow, vec4 P)` was honest-
// errored ("WGSL has no projective depth-compare sampling") even though it has a
// faithful lowering. glslang encodes it as coord=(P.x,P.y,P.w,P.w), Dref=P.z, and
// SPIR-V's OpImageSampleProjDref divides BOTH the coordinate AND the Dref by the
// coordinate's last component — so the correct WGSL is
//   textureSampleCompare(t, s, P.xy / P.w, P.z / P.w)
// (mirrors the non-Dref projective handler, which already does the coord divide).
// Dropping the Dref divide is silent-wrong (naga accepts it); this test pins BOTH
// divides via the divisor appearing twice, plus naga as ground truth. (#170)
test "wgsl: textureProj(sampler2DShadow) lowers to a projective textureSampleCompare" {
    const spirv = try compileToSpirv("proj_shadow_2d",
        \\#version 450
        \\layout(binding = 0) uniform sampler2DShadow sh;
        \\layout(location = 0) in vec4 P;
        \\layout(location = 0) out float o;
        \\void main() { o = textureProj(sh, P); }
    );
    defer alloc.free(spirv);
    // Previously error.UnsupportedOp; must now emit valid WGSL.
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "texture_depth_2d");
    try assertContains(wgsl, "sampler_comparison");
    try assertContains(wgsl, "textureSampleCompare(");
    // The spatial coordinate must be sliced to .xy and perspective-divided...
    try assertContains(wgsl, ".xy /");
    // ...and the perspective divide must apply to BOTH the coordinate and the
    // depth reference (the bug the old honest-error claimed was unavoidable): the
    // single divisor expression therefore appears at least twice in the call.
    try std.testing.expect(std.mem.count(u8, wgsl, " / ") >= 2);
    try nagaValidateOrSkip(wgsl, "proj-shadow-2d");
}

// ---------------------------------------------------------------------------
// Non-depth ARRAY textures (sampler2DArray, samplerCubeArray, ...). Mirrors the
// depth-array path: the type name must carry `_array` AND the sample/fetch/gather
// call must split the array layer out as a SEPARATE i32 argument. Emitting the
// non-array type (texture_2d<f32>) with the full packed coordinate is silent-
// wrong at the glslpp level (exit 0) but naga REJECTS it ("coordinate type does
// not match dimension"). This is the #187 PART B fix.
// ---------------------------------------------------------------------------

const ArrayTexCase = struct {
    name: []const u8,
    source: [:0]const u8,
    /// Exact texture declaration line — proves the `_array` type name (rules out
    /// the silent-wrong non-array `texture_2d<f32>` / `texture_cube<f32>`).
    tex_decl: []const u8,
    /// The sample/fetch/gather builtin that must still be emitted.
    builtin: []const u8,
    /// Spatial coordinate swizzle proving the layer was sliced off (.xy for the
    /// 2D family, .xyz for cube).
    coord_swizzle: []const u8,
    /// Distinguishing tail of the SEPARATE i32 array-layer argument
    /// (e.g. ".z)" for 2d_array, ".w)" for cube_array). Proves the layer was
    /// passed as its own integer argument, not folded into the coordinate.
    array_index: []const u8,
    /// Whether the layer must be ROUNDED (`i32(round(coord.z))`). True for the
    /// FLOAT-coord sample/lod/gather sites (glslang parity: floor(layer+0.5));
    /// FALSE for the INTEGER-coord texelFetch site (layer already an integer,
    /// `i32(coord.z)` with NO round). Defaults to true.
    layer_rounded: bool = true,
};

fn runArrayTexValidTest(c: ArrayTexCase) !void {
    const spirv = try compileToSpirv(c.name, c.source);
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);

    // The arrayed texture must be emitted with its `_array` type name...
    try assertContains(wgsl, c.tex_decl);
    // ...the sample/fetch/gather builtin must still be present...
    const builtin_call = try std.fmt.allocPrint(alloc, "{s}(", .{c.builtin});
    defer alloc.free(builtin_call);
    try assertContains(wgsl, builtin_call);
    // ...the spatial coordinate must be sliced to the texture dimension...
    try assertContains(wgsl, c.coord_swizzle);
    // ...the array layer must be passed as its own i32 argument. The float-coord
    // sample/lod/gather sites must ROUND it (`i32(round(coord.z))`) for glslang
    // parity; the integer-coord texelFetch site must NOT round (`i32(coord.z)`).
    if (c.layer_rounded) {
        try assertContains(wgsl, "i32(round(");
    } else {
        try assertContains(wgsl, "i32(");
        try assertNotContains(wgsl, "i32(round(");
    }
    try assertContains(wgsl, c.array_index);
    // ...and no silent-wrong non-array sampled type must appear.
    try assertNotContains(wgsl, "texture_2d<f32>");
    try assertNotContains(wgsl, "texture_cube<f32>");
    // Ground truth: the emitted WGSL must actually validate.
    try nagaValidateOrSkip(wgsl, c.name);
}

test "wgsl: sampler2DArray texture() emits texture_2d_array + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_2d",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray arr;
        \\layout(location=0) in vec3 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = texture(arr, vC); }
        ,
        .tex_decl = "var arr: texture_2d_array<f32>;",
        .builtin = "textureSample",
        .coord_swizzle = ".xy",
        .array_index = ".z)",
    });
}

test "wgsl: samplerCubeArray texture() emits texture_cube_array + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_cube",
        .source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeArray arr;
        \\layout(location=0) in vec4 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = texture(arr, vC); }
        ,
        .tex_decl = "var arr: texture_cube_array<f32>;",
        .builtin = "textureSample",
        .coord_swizzle = ".xyz",
        .array_index = ".w)",
    });
}

test "wgsl: textureLod(sampler2DArray) emits textureSampleLevel + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_2d_lod",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray arr;
        \\layout(location=0) in vec3 vC;
        \\layout(location=1) in float vLod;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureLod(arr, vC, vLod); }
        ,
        .tex_decl = "var arr: texture_2d_array<f32>;",
        .builtin = "textureSampleLevel",
        .coord_swizzle = ".xy",
        .array_index = ".z)",
    });
}

test "wgsl: texelFetch(sampler2DArray) emits textureLoad + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_2d_fetch",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray arr;
        \\layout(location=0) flat in ivec3 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = texelFetch(arr, vC, 0); }
        ,
        .tex_decl = "var arr: texture_2d_array<f32>;",
        .builtin = "textureLoad",
        .coord_swizzle = ".xy",
        .array_index = ".z)",
        // texelFetch coord is INTEGER — the layer must NOT be rounded.
        .layer_rounded = false,
    });
}

test "wgsl: textureGather(sampler2DArray) emits textureGather + separate layer arg" {
    try runArrayTexValidTest(.{
        .name = "arr_2d_gather",
        .source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray arr;
        \\layout(location=0) in vec3 vC;
        \\layout(location=0) out vec4 fragColor;
        \\void main(){ fragColor = textureGather(arr, vC, 0); }
        ,
        .tex_decl = "var arr: texture_2d_array<f32>;",
        .builtin = "textureGather",
        .coord_swizzle = ".xy",
        .array_index = ".z)",
    });
}

test "WGSL: unmapped ext-inst error names the GLSL.std.450 instruction" {
    // interpolateAtCentroid lowers to GLSL.std.450 InterpolateAtCentroid (76),
    // which has no WGSL equivalent. The honest error must NAME the instruction
    // (+ opcode) so the user knows what was unsupported — not a bare error name.
    const source =
        \\#version 450
        \\layout(location=0) in vec4 c;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = interpolateAtCentroid(c); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);

    try std.testing.expectError(
        error.UnsupportedExtInst,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );

    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "InterpolateAtCentroid") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "76") != null);
}

test "wgsl: geometry stage errors honestly (WGSL has no geometry entry point)" {
    // WGSL has only vertex/fragment/compute entry points. A geometry shader must
    // fail loud with a named error, not emit WGSL that naga rejects (silent-wrong).
    const source =
        \\#version 450
        \\layout(triangles) in;
        \\layout(triangle_strip, max_vertices = 3) out;
        \\void main() {
        \\    for (int i = 0; i < 3; i++) { gl_Position = gl_in[i].gl_Position; EmitVertex(); }
        \\    EndPrimitive();
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .geometry, .spirv_version = .@"1.5" });
    defer alloc.free(spirv);

    try std.testing.expectError(error.UnsupportedStage, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "Geometry") != null);
}

test "wgsl: scalar isnan lowers to (x != x); scalar isinf to a naga-valid idiom" {
    // WGSL has no isNan/isInf builtins. Scalar isnan(x) lowers to (x != x); scalar
    // isinf(x) lowers to the literal-free idiom (x != 0.0 && x*2.0 == x) (#170).
    // Neither may emit the non-existent isnan(...)/isinf(...) builtin (naga rejects
    // those as undefined identifiers — silent-wrong).
    {
        const source =
            \\#version 450
            \\layout(location=0) in float a;
            \\layout(location=0) out vec4 o;
            \\void main() { o = vec4(isnan(a) ? 1.0 : 0.0); }
        ;
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
        defer alloc.free(spirv);
        const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
        defer alloc.free(wgsl);
        // Pin the (x != x) let-binding idiom, not just any `!=` in the output.
        try std.testing.expect(std.mem.indexOf(u8, wgsl, "bool = (") != null);
        try std.testing.expect(std.mem.indexOf(u8, wgsl, "isnan(") == null);
        try nagaValidateOrSkip(wgsl, "isnan-scalar");
    }
    {
        const source =
            \\#version 450
            \\layout(location=0) in float a;
            \\layout(location=0) out vec4 o;
            \\void main() { o = vec4(isinf(a) ? 1.0 : 0.0); }
        ;
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
        defer alloc.free(spirv);
        const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
        defer alloc.free(wgsl);
        try std.testing.expect(std.mem.indexOf(u8, wgsl, "isinf(") == null);
        try std.testing.expect(std.mem.indexOf(u8, wgsl, "isInf") == null);
        try nagaValidateOrSkip(wgsl, "isinf-scalar");
    }
}

test "wgsl: textureQueryLod errors honestly (WGSL has no equivalent)" {
    // WGSL has no textureQueryLod builtin; glslpp must fail loud, not emit
    // textureQueryLod(...) which naga rejects (silent-wrong).
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D t;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(textureQueryLod(t, uv), 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "textureQueryLod") != null);
}

test "wgsl: fragment-shader interlock errors honestly (WGSL has no interlock)" {
    // WGSL has no fragment-shader interlock. A shader with the pixel-interlock
    // execution mode must fail loud, not emit WGSL naga rejects (silent-wrong).
    const source =
        \\#version 450
        \\#extension GL_ARB_fragment_shader_interlock : require
        \\layout(pixel_interlock_ordered) in;
        \\layout(location=0) out vec4 o;
        \\void main() { beginInvocationInterlockARB(); o = vec4(1.0); endInvocationInterlockARB(); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "interlock") != null);
}

// #170: OpLogicalEqual (164) / OpLogicalNotEqual (165) — GLSL bool `==`/`!=` and
// `equal`/`notEqual` on bvecN — had no WGSL mapping and honest-errored, even though
// WGSL's `==`/`!=` operators apply directly to bool (and componentwise to vecN<bool>).
// glslang is the oracle (these opcodes are emitted by boolean comparisons).
test "wgsl: scalar bool ==/!= (OpLogicalEqual/NotEqual) lower to naga-valid operators (#170)" {
    const spirv = try compileToSpirv("logical_eq_scalar",
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    bool a = uv.x > 0.3;
        \\    bool b = uv.x < 0.7;
        \\    bool eq = (a == b);
        \\    bool ne = (a != b);
        \\    fragColor = vec4(eq ? 1.0 : 0.0, ne ? 1.0 : 0.0, 0.0, 1.0);
        \\}
    );
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "logical-eq-scalar");
}

test "wgsl: bvec equal/notEqual (vector OpLogicalEqual/NotEqual) lower componentwise (#170)" {
    const spirv = try compileToSpirv("logical_eq_vec",
        \\#version 450
        \\layout(location = 0) flat in ivec4 iv;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    bvec2 a = bvec2(iv.x > 0, iv.y > 0);
        \\    bvec2 b = bvec2(iv.z > 0, iv.w > 0);
        \\    bvec2 e = equal(a, b);
        \\    bvec2 n = notEqual(a, b);
        \\    fragColor = vec4(float(e.x), float(n.y), 0.0, 1.0);
        \\}
    );
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "logical-eq-vec");
}

// A SPIR-V opcode that glslpp's `Op` enum does not NAME (here OpUMulExtended=151,
// emitted by GLSL `umulExtended`) must fail loud with error.UnsupportedOp — never
// crash. The honest-error fallback formatted the op via `@tagName(inst.op)`, which
// PANICS ("invalid enum value") on a non-exhaustive enum value with no matching
// field, so the process aborted on perfectly valid glslang SPIR-V instead of
// reporting the honest error. `umulExtended` needs a u64 intermediate that core
// WGSL lacks, so unlike uaddCarry/usubBorrow it stays a (loud) honest error — and
// it is still a tag-less opcode, so it exercises the same `@tagName`-panic path.
// glslpp's own frontend rejects `umulExtended`, so glslang is the oracle. (#170)
test "wgsl: an opcode the Op enum doesn't name fails loud, not a @tagName panic (#170)" {
    const spirv = try compileToSpirv("umulextended_honest",
        \\#version 450
        \\layout(location = 0) flat in uvec2 v;
        \\layout(location = 0) out uvec2 o;
        \\void main() {
        \\    uint msb;
        \\    uint lsb;
        \\    umulExtended(v.x, v.y, msb, lsb);
        \\    o = uvec2(lsb, msb);
        \\}
    );
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    // The detail must identify the unnamed op by its numeric opcode (151) rather
    // than crash trying to look up a non-existent enum tag name.
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "151") != null);
}

// #170: OpIAddCarry / OpISubBorrow (GLSL uaddCarry/usubBorrow) return a 2-member
// {result, carry|borrow} struct that is consumed only by OpCompositeExtract. They
// have no struct-returning WGSL builtin, but each member IS representable: member 0
// is the wrapping add/sub (WGSL u32 arithmetic wraps, matching SPIR-V), member 1 is
// the carry/borrow recovered with `select`. These feed glslang's struct-result
// SPIR-V (OpIAddCarry) to exercise the WGSL BACK-END's struct-member recovery —
// glslpp's own frontend now EMULATES these with core ops (add + ULessThan + select)
// rather than emitting OpIAddCarry, covered by the full-pipeline test below.
test "wgsl: scalar uaddCarry lowers to a naga-valid select idiom (#170)" {
    const spirv = try compileToSpirv("uaddcarry_scalar",
        \\#version 450
        \\layout(location = 0) flat in uvec2 v;
        \\layout(location = 0) out uvec2 o;
        \\void main() {
        \\    uint carry;
        \\    uint s = uaddCarry(v.x, v.y, carry);
        \\    o = uvec2(s, carry);
        \\}
    );
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Carry is recovered via select (no struct-returning builtin leaks).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "select(") != null);
    // The wrapping sum (member 0) is a plain addition.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, " + ") != null);
    try nagaValidateOrSkip(wgsl, "uaddcarry-scalar");
}

test "wgsl: scalar usubBorrow lowers to a naga-valid select idiom (#170)" {
    const spirv = try compileToSpirv("usubborrow_scalar",
        \\#version 450
        \\layout(location = 0) flat in uvec2 v;
        \\layout(location = 0) out uvec2 o;
        \\void main() {
        \\    uint borrow;
        \\    uint d = usubBorrow(v.x, v.y, borrow);
        \\    o = uvec2(d, borrow);
        \\}
    );
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Borrow is recovered via select on a less-than comparison.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "select(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, " - ") != null);
    try nagaValidateOrSkip(wgsl, "usubborrow-scalar");
}

test "wgsl: vector uaddCarry lowers componentwise (naga-valid) (#170)" {
    const spirv = try compileToSpirv("uaddcarry_vec",
        \\#version 450
        \\layout(location = 0) flat in uvec4 v;
        \\layout(location = 0) out uvec4 o;
        \\void main() {
        \\    uvec2 carry;
        \\    uvec2 s = uaddCarry(v.xy, v.zw, carry);
        \\    o = uvec4(s, carry);
        \\}
    );
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "select(") != null);
    try nagaValidateOrSkip(wgsl, "uaddcarry-vec");
}

test "wgsl: vector usubBorrow lowers componentwise (naga-valid) (#170)" {
    const spirv = try compileToSpirv("usubborrow_vec",
        \\#version 450
        \\layout(location = 0) flat in uvec4 v;
        \\layout(location = 0) out uvec4 o;
        \\void main() {
        \\    uvec2 borrow;
        \\    uvec2 d = usubBorrow(v.xy, v.zw, borrow);
        \\    o = uvec4(d, borrow);
        \\}
    );
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "select(") != null);
    try nagaValidateOrSkip(wgsl, "usubborrow-vec");
}

// #170: the FULL glslpp pipeline (frontend emulation → WGSL) for uaddCarry, with
// the carry written DIRECTLY to an SSBO member out-parameter (`b.c`, not a temp).
// Exercises analyzeLValue-on-SSBO-member for the store, the core-op emulation
// (add + ULessThan + select), and naga validity end-to-end.
test "wgsl: uaddCarry full pipeline with SSBO-member out-param is naga-valid (#170)" {
    const wgsl = compileCompToWgsl(
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { uint a, b, s, c; };
        \\void main() { s = uaddCarry(a, b, c); }
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "select(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, " + ") != null);
    try nagaValidateOrSkip(wgsl, "uaddcarry-ssbo-fullpipe");
}

// #170: a mixed int/uint `max` (and min/clamp) previously emitted WGSL
// `max(i32, u32)` — naga REJECTS it ("inconsistent type passed as argument #2").
// GLSL promotes to unsigned, so the signed operand must be bitcast and the result
// is unsigned: `max(bitcast<u32>(si), ui)`, which naga accepts.
test "wgsl: mixed int/uint max is naga-valid (was an inconsistent-type reject) (#170)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location=0) flat in int si;
        \\layout(location=1) flat in uint ui;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(float(max(si, ui)), float(min(si, ui)), float(clamp(si, 0u, ui)), 1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "mixed-int-uint-minmax");
}

// #170: a VECTOR-primary mixed-sign min/max/clamp with SCALAR edges
// (`clamp(uvec3, int, int)`, `max(ivec2, uint)`) must promote BOTH the signedness
// (bitcast) AND the scalar edges to the vector dimension — emitting a U-variant
// with mismatched scalar/vector operands would be invalid SPIR-V. naga rejects any
// malformed result, so passing validation confirms both promotions happened.
test "wgsl: vector mixed-sign min/max/clamp with scalar edges is naga-valid (#170)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location=0) flat in ivec3 iv;
        \\layout(location=1) flat in uvec3 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\    uvec3 a = clamp(uv, 2, 9);          // uvecN x, scalar int edges
        \\    uvec3 b = max(iv, 3u);              // ivecN x, scalar uint edge
        \\    ivec3 c = min(iv, uvec3(5u));       // ivecN x, uvecN edge
        \\    o = vec4(float(a.x + b.y) + float(c.z), 0.0, 0.0, 1.0);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "vector-mixed-sign-minmax-scalar-edges");
}

test "wgsl: unmapped input built-in (gl_PointCoord) errors honestly" {
    // gl_PointCoord has no WGSL @builtin. It must fail loud — previously it hit
    // an `else => \"position\"` fallback that fabricated a bogus
    // @builtin(position): vec2f (naga reject, silent-wrong).
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() { fragColor = vec4(gl_PointCoord, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "@builtin") != null);
}

test "wgsl: vertex input without explicit location is still emitted as a param" {
    // `in vec4 inV;` (no layout location) must become an `@location(N)` entry
    // parameter; previously inputs lacking a Location decoration were dropped,
    // leaving the body referencing an undeclared identifier (naga reject).
    const source =
        \\#version 450
        \\in vec4 inV;
        \\layout(location = 0) out vec4 vColor;
        \\void main() { vColor = inV; gl_Position = inV; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "inV: vec4f") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(") != null);
}

test "wgsl: vertex shader without gl_Position errors honestly" {
    // WGSL requires a @builtin(position) vertex output. A vertex shader that
    // never writes gl_Position cannot be valid WGSL; fabricating one would be
    // silent-wrong, so glslpp must fail loud.
    const source =
        \\#version 430 core
        \\in vec4 inV;
        \\layout(location = 0) out vec4 outV;
        \\void main() { outV = inV; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "gl_Position") != null);
}

test "wgsl: external glslang vertex shader (gl_PerVertex block) compiles" {
    // glslang wraps gl_Position in a member-decorated `gl_PerVertex` Block output
    // struct (OpMemberDecorate <struct> 0 BuiltIn Position; written via
    // OpAccessChain <var> 0 + OpStore), NOT a direct Position-decorated output var
    // like glslpp's own frontend. The WGSL output-collection only looked at
    // VAR-level builtins, so EVERY external glslang vertex shader honest-errored
    // ("requires a gl_Position output"). The block's member 0 must be recognized
    // as the @builtin(position) output. (#170)
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec3 pos;
        \\layout(location=0) out vec3 col;
        \\void main(){ gl_Position = vec4(pos, 1.0); col = pos; }
    ;
    const spirv = compileVertToSpirv("pervertex_block", source) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@vertex") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@builtin(position)") != null);
    // The position varying carries through and gl_Position is actually written.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "gl_Position =") != null);
    try nagaValidateOrSkip(wgsl, "pervertex-block");
}

test "wgsl: external glslang vertex shader writing only gl_Position compiles" {
    // gl_PerVertex block with no @location varyings — only gl_Position written.
    // A VertexOutput with a single @builtin(position) field is valid WGSL; the
    // body stores through `vertex_out.gl_Position`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec3 pos;
        \\void main(){ gl_Position = vec4(pos, 1.0); }
    ;
    const spirv = compileVertToSpirv("pervertex_posonly", source) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@vertex") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@builtin(position)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "gl_Position =") != null);
    try nagaValidateOrSkip(wgsl, "pervertex-posonly");
}

test "wgsl: external glslang vertex shader writing gl_PointSize errors honestly" {
    // The gl_PerVertex block's gl_PointSize (member 1) has no WGSL output. If the
    // shader writes it, glslpp must fail loud rather than silently drop it.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec3 pos;
        \\void main(){ gl_Position = vec4(pos, 1.0); gl_PointSize = 2.0; }
    ;
    const spirv = compileVertToSpirv("pervertex_pointsize", source) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    // Must fail because of gl_PointSize specifically — not because gl_Position
    // went unrecognized (the pre-fix failure mode).
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "PointSize") != null or
        std.mem.indexOf(u8, detail, "point") != null);
}

test "wgsl: shared block var is renamed to avoid struct-name collision" {
    // A GLSL `shared` block with no instance name yields a struct and a var both
    // named `blk`. WGSL forbids a variable sharing its name with its type (naga:
    // "redefinition of `blk`"). The var must be renamed (struct keeps its name).
    const source =
        \\#version 450
        \\#extension GL_EXT_shared_memory_block : enable
        \\layout(local_size_x = 8) in;
        \\shared blk { int a; } ;
        \\void main() { blk.a = 2; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "struct blk {") != null);
    // The variable must NOT also be named exactly `blk` (no `var<workgroup> blk:`).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<workgroup> blk:") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<workgroup> blk_wg:") != null);
}

test "wgsl: gl_Layer / gl_ViewportIndex error honestly (no WGSL built-in)" {
    // WGSL has no layer/viewport-index built-in. A shader using gl_Layer (BuiltIn
    // Layer) must fail loud, not leak `gl_Layer` as an undeclared identifier or
    // misclassify it as a @location varying (naga reject).
    const source =
        \\#version 450
        \\#extension GL_ARB_shader_viewport_layer_array : require
        \\layout(location=0) out vec4 color;
        \\void main() { color = vec4(float(gl_Layer)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "layer") != null);
}

test "wgsl: constant unsigned vector uses WGSL vec constructor, not GLSL uintN" {
    // A uvec2 constant composite must render as `vec2<u32>(...)`, not the GLSL
    // spelling `uint2(...)` / `uvec2i(...)` which naga rejects as an undefined
    // identifier.
    const source =
        \\#version 450
        \\layout(location = 0) in vec2 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uvec2 a = uvec2(v) & uvec2(7u, 15u);
        \\    o = vec4(vec2(a), 0.0, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vec2<u32>(7u, 15u)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uint2(") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uvec2") == null);
}

test "wgsl: unsupported op in switch/loop replay path errors honestly" {
    // A cross-vector OpVectorShuffle inside a switch reaches the switch/loop
    // replay path (emitSimpleInstruction). Ops with no case there must fail loud,
    // not fall to the old fallback that emitted `<OpcodeName>(args)` (a call to a
    // non-existent WGSL function — naga reject, silent-wrong).
    const source =
        \\#version 450
        \\layout(location = 0) in vec4 a;
        \\layout(location = 1) in vec4 b;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 c = vec4(0.0);
        \\    int m = int(a.x) % 3;
        \\    switch (m) {
        \\        case 0: c = vec4(a.xy, b.zw); break;
        \\        case 1: c = b.wzyx; break;
        \\        default: c = a; break;
        \\    }
        \\    o = c;
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "replay") != null);
}

test "wgsl: textureGather emits the component as the first argument" {
    // WGSL: textureGather(component, texture, sampler, coords). The GLSL order
    // (tex, sampler, coords, component) makes naga read the texture where it
    // expects the integer component ("must resolve to u32 or i32").
    const source =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D uTex;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureGather(uTex, uv, 0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Component (0) comes first, before the texture identifier.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "textureGather(0, uTex, uTex_sampler, uv)") != null);
}

test "wgsl: CompositeExtract/Select in loop-replay path do not leak opcode names" {
    // A while(true)+switch state machine drives the switch/loop replay path
    // (emitSimpleInstruction). OpCompositeExtract / OpSelect there must lower to
    // an inline access expr / select(...), not leak as `CompositeExtract(...)` /
    // `Select(...)` (opcode names, naga reject) nor `var v.x: T = ...`.
    const source =
        \\#version 450
        \\layout(location = 0) in vec3 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    int state = 0;
        \\    vec3 acc = vec3(0.0);
        \\    while (true) {
        \\        switch (state) {
        \\            case 0: acc.x = v.x; state = (v.x > 0.5) ? 2 : 1; break;
        \\            case 1: acc.y = v.y; state = 3; break;
        \\            default: state = 3; break;
        \\        }
        \\        if (state == 3) break;
        \\    }
        \\    o = vec4(acc, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "CompositeExtract") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "Select(") == null);
}

test "wgsl: nested switch does not leak OpSelectionMerge as a value" {
    // A nested switch drives the switch/loop replay path. OpSelectionMerge (a
    // structured-control-flow hint with no result id) must be skipped there, not
    // emitted as `let v = SelectionMerge();` (which naga rejects: "no definition
    // in scope for identifier: SelectionMerge").
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int mode = int(gl_FragCoord.x) % 4;
        \\    vec3 color = vec3(0.0);
        \\    switch (mode) {
        \\        case 0: color = vec3(1.0, 0.0, 0.0); break;
        \\        case 1: {
        \\            int sub = int(gl_FragCoord.y) % 2;
        \\            switch (sub) {
        \\                case 0: color = vec3(0.0, 1.0, 0.0); break;
        \\                default: color = vec3(0.0, 0.0, 1.0); break;
        \\            }
        \\            break;
        \\        }
        \\        default: color = vec3(0.5); break;
        \\    }
        \\    fragColor = vec4(color, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "SelectionMerge") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "LoopMerge") == null);
}

test "wgsl: QCOM block-match errors honestly (WGSL has no QCOM image ops)" {
    // GL_QCOM_image_processing block-match has no WGSL equivalent. glslpp must
    // fail loud instead of falling through to the `var v: T;` placeholder, which
    // produces silent-wrong WGSL that naga rejects ("redefinition of `v`").
    const source =
        \\#version 450
        \\#extension GL_QCOM_image_processing : require
        \\precision highp float;
        \\layout(location = 0) in vec4 v_texcoord;
        \\layout(location = 0) out vec4 fragColor;
        \\layout(set = 0, binding = 0) uniform sampler2D target_samp;
        \\layout(set = 0, binding = 1) uniform sampler2D ref_samp;
        \\void main() {
        \\    uvec2 t = uvec2(v_texcoord.xy);
        \\    uvec2 r = uvec2(v_texcoord.zw);
        \\    fragColor = textureBlockMatchSADQCOM(target_samp, t, ref_samp, r, uvec2(4, 4));
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "QCOM") != null);
}

// ---------------------------------------------------------------------------
// row_major / column_major UBO matrix layout (silent-wrong fix)
//
// WGSL has no row_major language feature — matrices are always column-major and
// `m[i]` returns COLUMN i (like GLSL/MSL). So the column_major case is already
// correct, but glslpp emitted byte-identical WGSL for a row_major block: a
// row_major matrix's std140 bytes are the row-major layout of M, which WGSL
// reads (column-major) as Mᵀ — silent-wrong. The fix mirrors the MSL backend:
// wrap reads of a row_major matrix in `transpose(...)` so the stored Mᵀ is read
// back as the logical M. Non-square row_major needs swapped declared dimensions
// (not yet implemented) → honest error, never silent-wrong.
// ---------------------------------------------------------------------------

const WRM_ROW_SRC: [:0]const u8 =
    \\#version 450
    \\layout(binding=0,std140,row_major) uniform A { mat4 m; } a;
    \\layout(location=0) out vec4 o;
    \\void main() { o = a.m[0]; }
;
const WRM_COL_SRC: [:0]const u8 =
    \\#version 450
    \\layout(binding=0,std140,column_major) uniform A { mat4 m; } a;
    \\layout(location=0) out vec4 o;
    \\void main() { o = a.m[0]; }
;

test "wgsl: row_major UBO matrix read is transposed; column_major is not; outputs differ" {
    const row = try compileToWgsl(WRM_ROW_SRC);
    defer alloc.free(row);
    const col = try compileToWgsl(WRM_COL_SRC);
    defer alloc.free(col);

    // Core bug: blocks differing only in layout qualifier must NOT be identical.
    if (std.mem.eql(u8, row, col)) {
        std.debug.print("row_major and column_major WGSL are byte-identical (silent-wrong):\n{s}\n", .{row});
        return error.TestUnexpectedFind;
    }
    // row_major is stored transposed → the read must transpose() it back.
    // Exact form (not a stray `transpose`) so a mis-wrapped transpose still fails.
    try assertContains(row, "transpose(a.m)[0]");
    // column_major is already correct in WGSL (column-indexed) → no transpose.
    try assertNotContains(col, "transpose");
    // Ground truth: the transposed output must actually validate.
    try nagaValidateOrSkip(row, "row_major mat4 read");
    try nagaValidateOrSkip(col, "column_major mat4 read");
}

test "wgsl: array-of-row_major matrix reads are transposed; column_major arrays are not" {
    // `mat4 m[4]` reaches the matrix via an array index. A row_major array
    // element is still stored transposed in WGSL, so both a whole-element load
    // (a.m[2], for mul) and a column read (a.m[2][0]) must transpose. The
    // column_major array stays untransposed (already correct, column-indexed).
    const row_src: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,row_major) uniform A { mat4 m[4]; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[2][0]; }
    ;
    const col_src: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,column_major) uniform A { mat4 m[4]; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[2][0]; }
    ;
    const row = try compileToWgsl(row_src);
    defer alloc.free(row);
    const col = try compileToWgsl(col_src);
    defer alloc.free(col);
    try assertContains(row, "transpose(a.m[2])[0]");
    try assertNotContains(col, "transpose");
    try nagaValidateOrSkip(row, "row_major mat4[4] read");
    try nagaValidateOrSkip(col, "column_major mat4[4] read");
}

test "wgsl: whole row_major matrix load feeding mul IS transposed (no row_major keyword in WGSL)" {
    // Unlike HLSL, WGSL has no row_major storage keyword — a row_major matrix is
    // always stored as Mᵀ, so even a whole-matrix load feeding a multiply must
    // transpose (transpose(a.m) * v). The array test's comment promises this
    // case; verify it directly. column_major stays untransposed.
    const row_src: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,row_major) uniform A { mat4 m; } a;
        \\layout(location=0) in vec4 v;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m * v; }
    ;
    const col_src: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,column_major) uniform A { mat4 m; } a;
        \\layout(location=0) in vec4 v;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m * v; }
    ;
    const row = try compileToWgsl(row_src);
    defer alloc.free(row);
    const col = try compileToWgsl(col_src);
    defer alloc.free(col);
    try assertContains(row, "transpose(a.m)");
    try assertNotContains(col, "transpose");
    try nagaValidateOrSkip(row, "row_major mat4 mul");
    try nagaValidateOrSkip(col, "column_major mat4 mul");
}

test "wgsl: non-square row_major UBO matrix is an honest error (not silent-wrong)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0,std140,row_major) uniform A { mat3x4 m; } a;
        \\layout(location=0) out vec4 o;
        \\void main() { o = a.m[0]; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(
        error.UnsupportedRowMajorMatrix,
        glslpp.spirvToWGSL(alloc, spirv, .{}),
    );
}

test "wgsl: gl_VertexIndex/gl_InstanceIndex emit u32 @builtin with i32 conversion" {
    // WGSL mandates u32 for vertex_index/instance_index, but glslang types them
    // as signed i32. Emitting i32 makes naga reject the entry point. We emit a
    // u32 parameter and a converting `let ...: i32 = i32(...)` for body uses.
    const source =
        \\#version 450
        \\layout(location=0) out vec4 col;
        \\void main() {
        \\    gl_Position = vec4(float(gl_VertexIndex), float(gl_InstanceIndex), 0.0, 1.0);
        \\    col = vec4(1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@builtin(vertex_index) gl_VertexIndex_b: u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@builtin(instance_index) gl_InstanceIndex_b: u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "let gl_VertexIndex: i32 = i32(gl_VertexIndex_b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "let gl_InstanceIndex: i32 = i32(gl_InstanceIndex_b);") != null);
    // The invalid signed builtin must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@builtin(vertex_index) gl_VertexIndex: i32") == null);
}

test "wgsl: passthrough fragment store emits a defined return identifier (not freed-memory garbage)" {
    // Regression: `o = vIn` (and `o = -(-vIn)` after double-negate folding)
    // feeds an OpLoad whose result emitBody inlines to the source name (`vIn`)
    // and never emits as a `let`. The direct-return optimization captured the
    // load's *pre-emitBody* generated name (`v6`), producing `return v6;` where
    // v6 is undefined — and worse, an aliased+freed slice surfaced as
    // `return \xAA\xAA;` (freed-memory fill). Both are silent-wrong; naga rejects.
    const passthrough: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 vIn;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vIn; }
    ;
    const double_negate: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 vIn;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = -(-vIn); }
    ;
    inline for (.{ passthrough, double_negate }) |source| {
        const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
        defer alloc.free(spirv);
        const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
        defer alloc.free(wgsl);
        // The return value must be the in-scope input identifier, never an
        // undefined generated name or freed-memory bytes.
        try std.testing.expect(std.mem.indexOf(u8, wgsl, "return vIn;") != null);
        // The freed-memory fill byte (0xAA) must never appear: it is the
        // signature of the use-after-free this guards against. (The header
        // comment legitimately contains a UTF-8 `→`, so a blanket ASCII-only
        // check would be wrong.)
        for (wgsl) |c| try std.testing.expect(c != 0xAA);
    }
}

test "wgsl: MRT passthrough stores emit defined identifiers (not freed-memory garbage)" {
    // Same hazard as the single-output direct return, but on the multi-render-
    // target path: `o0 = vIn; o1 = vIn;` captured each stored value's name
    // pre-emitBody, surfacing as `return FragmentOutput(\xAA\xAA, \xAA\xAA);`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 vIn;
        \\layout(location=0) out vec4 o0;
        \\layout(location=1) out vec4 o1;
        \\void main(){ o0 = vIn; o1 = vIn; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "return FragmentOutput(vIn, vIn);") != null);
    for (wgsl) |c| try std.testing.expect(c != 0xAA);
}

test "wgsl: gl_FragDepth passthrough store emits a defined identifier (not freed-memory garbage)" {
    // The frag-depth return path shared the same pre-emitBody name capture:
    // `gl_FragDepth = d;` (a passthrough load) surfaced as a \xAA depth operand.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in float d;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(1.0); gl_FragDepth = d; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // depth operand must be the in-scope input `d`, not an undefined name.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ", d);") != null);
    for (wgsl) |c| try std.testing.expect(c != 0xAA);
}

test "wgsl: heavily-used immutable input load inlines to its name in inline expressions" {
    // Regression: an input read in many branches (>6 uses) was NOT inlined to its
    // source name by the load-inlining pass (a `uses <= 6` cap) AND never emitted
    // as a `let`, so inline expressions referenced an undefined `vN` — e.g. a
    // nested if/else chain produced `(v9 - 0.25) * 4.0` where `v9` is never
    // declared (naga: "no definition in scope for identifier: `v9`").
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float result;
        \\    if (u < 0.25) { result = u * 4.0; }
        \\    else if (u < 0.5) { result = 1.0 - (u - 0.25) * 4.0; }
        \\    else if (u < 0.75) { result = (u - 0.5) * 4.0; }
        \\    else { result = 1.0 - (u - 0.75) * 4.0; }
        \\    fragColor = vec4(result, result * 0.5, result * 0.25, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The immutable input `u` must appear in the arithmetic; no undefined `v9`.
    // (Scalar float constants are now typed with an `f` suffix — #170 G5 Pass 2 —
    // so the literal renders as `0.25f`.)
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "(u - 0.25f)") != null);
    // No bare reference to an undefined load temp like `v9 ` (the input is `u`).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "v9 -") == null);
    for (wgsl) |c| try std.testing.expect(c != 0xAA);
}

test "wgsl: direct recursion is an honest error (WGSL forbids recursion)" {
    // WGSL disallows any call-graph cycle. A recursive function must fail loud,
    // not emit a self-calling WGSL function that naga rejects.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\int fib(int n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }
        \\void main(){ o = vec4(float(fib(5))); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedRecursion, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: non-recursive nested function calls still compile (no false recursion flag)" {
    // Guard against the recursion detector over-firing on a normal call chain.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\vec2 inner(vec2 p) { return p * 2.0; }
        \\vec2 outer(vec2 p) { return inner(p) + p; }
        \\void main(){ o = vec4(outer(uv), 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(wgsl.len > 0);
}

// Naming-independent scope check: every `vN` temp referenced in the WGSL must be
// declared somewhere (let/var). Catches the undefined-identifier silent-wrong
// class — e.g. a loop-carried phi update leaking into a later loop where its
// value temp is out of scope (`v18 = v23` with v23 never declared).
fn assertNoUndeclaredVTemp(wgsl: []const u8) !void {
    const isIdent = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_';
        }
    }.f;
    var declared = std.StringHashMap(void).init(alloc);
    defer {
        var it = declared.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        declared.deinit();
    }
    inline for (.{ "let ", "var " }) |kw| {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, wgsl, idx, kw)) |p| {
            idx = p + kw.len;
            var e = idx;
            while (e < wgsl.len and isIdent(wgsl[e])) e += 1;
            const name = wgsl[idx..e];
            if (name.len >= 2 and name[0] == 'v' and std.ascii.isDigit(name[1])) {
                const owned = try alloc.dupe(u8, name);
                if ((try declared.fetchPut(owned, {})) != null) alloc.free(owned);
            }
        }
    }
    var i: usize = 0;
    while (i < wgsl.len) : (i += 1) {
        if (wgsl[i] != 'v') continue;
        if (i > 0 and isIdent(wgsl[i - 1])) continue;
        if (i + 1 >= wgsl.len or !std.ascii.isDigit(wgsl[i + 1])) continue;
        var e = i;
        while (e < wgsl.len and isIdent(wgsl[e])) e += 1;
        const name = wgsl[i..e];
        // A `vN:` token is a declaration site (function parameter or typed
        // binding), not a use — record it as declared and move on.
        var j = e;
        while (j < wgsl.len and wgsl[j] == ' ') j += 1;
        if (j < wgsl.len and wgsl[j] == ':') {
            if (!declared.contains(name)) {
                const owned = try alloc.dupe(u8, name);
                if ((try declared.fetchPut(owned, {})) != null) alloc.free(owned);
            }
            i = e - 1;
            continue;
        }
        if (!declared.contains(name)) {
            std.debug.print("undeclared WGSL temp referenced: {s}\n", .{name});
            return error.UndeclaredTemp;
        }
        i = e - 1;
    }
}

test "wgsl: a loop without phis does not inherit a previous loop's phi update (scope leak)" {
    // Two consecutive loops: the second must not re-emit the first's loop-carried
    // back-edge update (which references a value temp scoped to the first loop).
    // Regression for the stale `pending_phi_start` phi-range mis-attribution.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out float o;
        \\void main(){
        \\  float a = 0.0;
        \\  for (int i = 0; i < 4; i++) { a += float(i); }
        \\  int k = 0;
        \\  for (; k < 5; k++) { a += 1.0; }
        \\  o = a + float(k);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertNoUndeclaredVTemp(wgsl);
}

test "wgsl: frexp/modf emit WGSL struct-return form (not the illegal pointer form)" {
    // GLSL frexp(x, out e)/modf(x, out i) lower to GLSL.std.450 Frexp/Modf
    // (pointer form). WGSL frexp(x)/modf(x) take ONE arg and return a struct:
    // frexp -> {fract, exp}, modf -> {fract, whole}. Emitting `frexp(x, ptr)`
    // was a naga reject ("too many arguments") AND dropped the exponent.
    const source: [:0]const u8 =
        "#version 310 es\nprecision mediump float;\n" ++
        "layout(location=0) out float FragColor;\nlayout(location=0) in float v0;\n" ++
        "void main(){\n  int e0; float f0 = frexp(v0, e0);\n  float r0; float m0 = modf(v0, r0);\n  FragColor = f0 + m0 + float(e0) + r0;\n}\n";
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Struct-return fields must be used; no 2-arg builtin call.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ".fract") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ".exp") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ".whole") != null);
    try assertNoUndeclaredVTemp(wgsl);
}

test "wgsl: a stage input used in a helper function is promoted to var<private>" {
    // WGSL @location inputs are entry-point parameters, not module globals, so a
    // helper that reads one would emit an undefined identifier. The input must be
    // promoted to a module-scope var<private>, bridged from the entry parameter.
    // (spec: docs/specs/2026-06-02-wgsl-cross-function-io.md)
    const source: [:0]const u8 =
        "#version 450\n" ++
        "layout(location=0) in vec2 uv;\n" ++
        "layout(location=0) out vec4 fragColor;\n" ++
        "float effect(vec2 p) { return length(p + uv); }\n" ++
        "void main(){ fragColor = vec4(effect(vec2(0.5))); }\n";
    // NoOpt so the helper is not inlined away — guarantees a genuine
    // cross-function reference to the input for this test.
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The input is a module-scope private global, bridged from a renamed param.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<private> uv: vec2f;") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uv_in: vec2f") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uv = uv_in;") != null);
    try assertNoUndeclaredVTemp(wgsl);
}

test "wgsl: a shader with NO cross-function input is unchanged (no spurious var<private>)" {
    // Gate check: when no input is used in a helper, nothing is promoted.
    const source: [:0]const u8 =
        "#version 450\n" ++
        "layout(location=0) in vec2 uv;\n" ++
        "layout(location=0) out vec4 fragColor;\n" ++
        "void main(){ fragColor = vec4(uv, 0.0, 1.0); }\n";
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<private> uv") == null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "uv_in") == null);
}

test "wgsl: an output read back in the body is declared as a local var (not direct-returned)" {
    // Partial writes + read-back of the output (e.g. modf.legacy's
    // `result.xy=…; result.zw=…` with `result.z` reads) must declare the output
    // as a zero-initialised `var` and return it — the direct-return optimization
    // would skip the declaration and leave the read referencing an undefined name.
    const source: [:0]const u8 =
        "#version 450\n" ++
        "layout(location=0) in vec2 v;\n" ++
        "layout(location=0) out vec4 o;\n" ++
        "void main(){ o.xy = v; o.zw = o.xy + o.zw; }\n";
    // NoOpt so the output read-back is preserved for the test.
    const spirv = try glslpp.compileToSPIRVNoOpt(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The output is a declared local var and is returned (not a bare reconstruction).
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var o: vec4f;") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "return o;") != null);
    try nagaValidateOrSkip(wgsl, "output-readback");
}

test "wgsl: clip-distance is an honest error, not a naga-invalid @location array" {
    // gl_ClipDistance is an array<f32,N> built-in; WGSL only allows numeric
    // scalars/vectors as user entry-point I/O (naga rejects the array), and
    // glslpp previously emitted `@location(N) gl_ClipDistance: array<f32,8>`
    // — naga-invalid (silent-wrong). It must fail loud instead.
    const source: [:0]const u8 =
        \\#version 450
        \\out gl_PerVertex { vec4 gl_Position; float gl_ClipDistance[1]; };
        \\layout(location=0) in vec4 p;
        \\void main(){ gl_Position = p; gl_ClipDistance[0] = p.x; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: stage output interface block is flattened into VertexOutput" {
    // GLSL `out Block { vec4 color; vec3 normal; } vout;` -> a struct-typed
    // Output. WGSL forbids a nested struct field in an I/O struct, so the block
    // members are flattened into VertexOutput and `vout.color` becomes
    // `vertex_out.color`. glslpp emitted `@location(0) vout: Block` (undeclared
    // nested struct) → naga "no definition in scope".
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 Position;
        \\out Block { vec4 color; vec3 normal; } vout;
        \\void main(){ gl_Position = Position; vout.color = vec4(1.0); vout.normal = vec3(0.5); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(0) color: vec4f") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(1) normal: vec3f") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vertex_out.color =") != null);
    // No nested struct field.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, ": Block") == null);
    try nagaValidateOrSkip(wgsl, "io-block-output");
}

test "wgsl: stage input interface block is declared as a struct with @location members" {
    // GLSL `in Block { flat float f; vec4 g; int h; } vin;` -> a struct-typed
    // Input variable. WGSL needs a struct with @location/@interpolate members
    // passed by value; glslpp emitted `@location(0) vin: Block` with the struct
    // undeclared (naga: "no definition in scope for identifier: Block").
    const source: [:0]const u8 =
        \\#version 450
        \\in Block { flat float f; vec4 g; flat int h; } vin;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(vin.f) + vin.g + vec4(float(vin.h)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "struct Block {") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(0) f: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(2) @interpolate(flat) h: i32") != null);
    // The param is a bare struct (members carry @location), not @location(N) vin.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vin: Block") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "@location(0) vin") == null);
    try nagaValidateOrSkip(wgsl, "io-block-input");
}

test "wgsl: struct constructed from vector components keeps per-field args" {
    // `Point(uv.x, uv.y)` must stay per-field; the vector-collapse simplification
    // (valid for `vec2(uv.x,uv.y)->uv`) wrongly produced `Point(uv)` — a vec2
    // passed to a 2-scalar struct, which naga rejects.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\struct P { float a; float b; };
        \\void main(){ P p = P(uv.x, uv.y); o = vec4(p.a, p.b, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "(uv.x, uv.y)") != null);
    try nagaValidateOrSkip(wgsl, "struct-from-vec");
}

test "wgsl: dual-source blending (two outputs at one @location) is an honest error" {
    // GLSL `layout(location=0, index=0/1)` dual-source blending → WGSL needs
    // @blend_src, but glslpp's SPIR-V drops the Index decoration, so the backend
    // can't tell src0 from src1. Emitting two @location(0) is naga-invalid
    // ("Multiple bindings at location 0"); fail loud instead.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0, index=0) out vec4 c0;
        \\layout(location=0, index=1) out vec4 c1;
        \\void main(){ c0 = vec4(1.0); c1 = vec4(2.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: depth-only fragment declares -> FragmentOutput return type" {
    // A shader writing only gl_FragDepth (no color output) returns
    // `FragmentOutput(...)` from its body, so the signature must declare the
    // return type. glslpp emitted `fn main()` (no return type) because
    // output_var_id was null → naga "Returning Some where None is expected".
    const source: [:0]const u8 =
        \\#version 450
        \\layout(depth_greater) out float gl_FragDepth;
        \\void main(){ gl_FragDepth = 0.5; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "-> FragmentOutput") != null);
    try nagaValidateOrSkip(wgsl, "depth-only");
}

test "wgsl: vector shift coerces the amount to vecN<u32>, not scalar u32" {
    // `uvec2(1) << uvec2(a,b)` — the WGSL shift amount must match the base's
    // vector dimension (`vec2<u32> << vec2<u32>`). glslpp wrapped it in scalar
    // `u32(...)` ("cannot cast a vec2<u32> to a u32"); scalar shifts keep `u32()`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) flat in uvec2 a;
        \\layout(location=0) out uvec2 o;
        \\void main(){ o = (uvec2(1u) << a) - 1u; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "vec2<u32>(") != null);
    try nagaValidateOrSkip(wgsl, "vec-shift");
}

test "wgsl: scalar geometric builtins lower to scalar ops (normalize->sign etc.)" {
    // GLSL allows normalize/length/distance on scalars; WGSL defines them only on
    // vectors (naga: "wrong type passed as argument #1 to `normalize`"). They must
    // lower: normalize(x)->sign(x), length(x)->abs(x), distance(a,b)->abs(a-b).
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { float a; float b; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(normalize(u.a), length(u.a), distance(u.a, u.b), 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "sign(") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "abs(") != null);
    // The vector-only builtins must NOT be emitted on scalars.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "normalize(") == null);
    try nagaValidateOrSkip(wgsl, "scalar-geom");
}

test "wgsl: scalar refract is an honest error (vector-only builtin, formula not faked)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { float i; float n; float e; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(refract(u.i, u.n, u.e)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: gl_PointSize is an honest error, not @builtin(__point_size)" {
    // WGSL points always render at 1px — there is no point-size output. glslpp
    // previously emitted `@builtin(__point_size)` (an invented builtin) which
    // naga rejects ("Identifier starts with a reserved prefix: `__point_size`").
    // The PointSize decoration only appears when the shader actually writes
    // gl_PointSize, so failing loud is correct: WGSL cannot honor the size.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 p;
        \\void main(){ gl_Position = p; gl_PointSize = 4.0; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: constant array of vectors uses array<vecN<T>,M>, not the scalar elem type" {
    // A `const vec3 pal[3]` lowered to an OpConstantComposite array previously
    // emitted `array<f32, 3>(vec3<f32>(...), ...)` — the element type was the
    // vector's SCALAR, a type mismatch naga rejects. The element must be the
    // full `vec3<f32>`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\    const vec3 pal[4] = vec3[4](vec3(1.0,0.0,0.0), vec3(0.0,1.0,0.0), vec3(0.0,0.0,1.0), vec3(1.0,1.0,0.0));
        \\    int idx = clamp(int(gl_FragCoord.x) / 64, 0, 3);
        \\    o = vec4(pal[idx], 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Element type is the vector (vec3f / vec3<f32>), never a bare scalar array.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "array<vec3") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "array<f32, 4>(") == null);
    try nagaValidateOrSkip(wgsl, "const-array-of-vec");
}

test "wgsl: constant array of structs uses array<StructName,N> element type" {
    // Extends the array-of-vectors fix to STRUCT (and nested-array) elements: an
    // `OpConstantComposite` array of structs previously emitted
    // `array<f32, 2>(Foobar(...), ...)` — scalar element type, a mismatch naga
    // rejects. The element must be the struct name `Foobar`.
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location=0) out vec4 o;
        \\struct Foobar { float a; float b; };
        \\void main(){
        \\    const Foobar foos[2] = Foobar[](Foobar(10.0, 40.0), Foobar(90.0, 70.0));
        \\    o = vec4(foos[0].a + foos[1].b);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "array<Foobar, 2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "array<f32, 2>(Foobar") == null);
    try nagaValidateOrSkip(wgsl, "const-array-of-struct");
}

test "wgsl: array element extract uses [i] indexing, not a .x swizzle" {
    // OpCompositeExtract of an array element (`arr[0]`) was inlined as `arr.x`
    // — a vector swizzle on an array — which naga rejects ("invalid field
    // accessor `x`"). Covers both a named local array and an inline constant
    // array literal (`array<vec4<f32>,2>(...)[0]`).
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\layout(location=0) in vec4 a;
        \\void main(){
        \\    vec4 vals[2] = vec4[2](a, a + vec4(1.0));
        \\    vec4 consts[2] = vec4[2](vec4(10.0), vec4(30.0));
        \\    o = vals[0] + vals[1] + consts[0];
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "array-extract-index");
}

test "wgsl: module-scope const array indexed at runtime emits its values" {
    // Regression: a `const T arr[N]` global indexed by a runtime value lowers to
    // a Private OpVariable carrying a constant-composite initializer. The "used"
    // check ignored OpAccessChain, so the declaration was skipped (`arr[i]`
    // referenced an undeclared name); and resolveConstantExpr didn't build array
    // literals, so even when declared it fell back to a zero-init var<private>
    // (wrong values = silent-wrong). Now: `const LUT: array<f32,4> =
    // array<f32,4>(1.0, 2.0, 3.0, 4.0);` and the access resolves to it. Index by
    // int(gl_FragCoord.x) to avoid the orthogonal integer-`flat`-input concern.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out float o;
        \\const float LUT[4] = float[](1.0, 2.0, 3.0, 4.0);
        \\void main(){ int i = int(gl_FragCoord.x) & 3; o = LUT[i]; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "array<f32, 4>(1.0, 2.0, 3.0, 4.0)");
    try assertNotContains(wgsl, "var<private> LUT"); // not a zero-init fallback
    try nagaValidateOrSkip(wgsl, "const-array-global");
}

test "wgsl: a reloaded input index keeps one name across recomputed sub-expressions" {
    // Regression (spirv-cross constant-array.frag / lut-promotion.frag): the
    // single load of a `flat in int index` is rendered INCONSISTENTLY — as the
    // input name `index` in the direct emission path but as its raw generated
    // `vN` inside a sub-expression that the running sum gets recomputed into
    // (triggered by re-evaluating function-call arguments). The recomputed `vN`
    // was never declared → naga "no definition in scope".
    //
    // Root cause: the AccessChain pre-scan froze the index operand using the
    // load's default name BEFORE the immutable-load name propagation ran, so the
    // inline expressions captured `v20` while direct emission used `index`. The
    // fix propagates immutable direct-variable load names before the AccessChain
    // pre-scan so a reloaded value is bound consistently everywhere.
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out vec4 FragColor;
        \\layout(location = 0) flat in int index;
        \\struct Foobar { float a; float b; };
        \\vec4 resolve(Foobar f) { return vec4(f.a + f.b); }
        \\void main() {
        \\   const vec4 foo[3] = vec4[](vec4(1.0), vec4(2.0), vec4(3.0));
        \\   const vec4 foobars[2][2] = vec4[][](vec4[](vec4(1.0), vec4(2.0)), vec4[](vec4(8.0), vec4(10.0)));
        \\   const Foobar foos[2] = Foobar[](Foobar(10.0, 40.0), Foobar(90.0, 70.0));
        \\   FragColor = foo[index] + foobars[index][index + 1] + resolve(Foobar(10.0, 20.0)) + resolve(foos[index]);
        \\}
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertNoUndeclaredVTemp(wgsl);
    try nagaValidateOrSkip(wgsl, "reloaded-index-def-drop");
}

test "wgsl: a reloaded output accumulator keeps one name across recomputed sub-expressions" {
    // Regression (spirv-cross lut-promotion.frag): the same def-drop class as the
    // index case, but for a reloaded OUTPUT. Successive `FragColor += …` reload
    // the output; a sub-expression recomputed into a later `+` froze the
    // `OpLoad %FragColor` as its raw `vN` (the is_output_load name propagation
    // only ran at emission, after the inline-expression pre-scan) → undeclared
    // `vN` (naga "no definition in scope"). The fix propagates output/input/
    // texture load names before the pre-scans.
    const source: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out float FragColor;
        \\layout(location = 0) flat in int index;
        \\const float LUT[16] = float[](
        \\    1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 4.0,
        \\    1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 4.0);
        \\void main() {
        \\    FragColor = LUT[index];
        \\    if (index < 10) FragColor += LUT[index ^ 1];
        \\    else FragColor += LUT[index & 1];
        \\    vec4 foo[4] = vec4[](vec4(0.0), vec4(1.0), vec4(8.0), vec4(5.0));
        \\    if (index > 30) FragColor += foo[index & 3].y;
        \\    else FragColor += foo[index & 1].x;
        \\    vec4 foobar[4] = vec4[](vec4(0.0), vec4(1.0), vec4(8.0), vec4(5.0));
        \\    if (index > 30) foobar[1].z = 20.0;
        \\    FragColor += foobar[index & 3].z;
        \\    vec4 baz[4] = vec4[](vec4(0.0), vec4(1.0), vec4(8.0), vec4(5.0));
        \\    baz = vec4[](vec4(20.0), vec4(30.0), vec4(50.0), vec4(60.0));
        \\    FragColor += baz[index & 3].z;
        \\}
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertNoUndeclaredVTemp(wgsl);
    try nagaValidateOrSkip(wgsl, "reloaded-output-def-drop");
}

// --- gap #170 Pass 1: deepen WGSL coverage ---------------------------------

test "wgsl: findMSB(uint) lowers to firstLeadingBit (GLSL.std.450 FindUMsb 75)" {
    // GLSL findMSB on an unsigned int emits GLSL.std.450 FindUMsb (75). It was
    // missing from the shared name table, so it hit recordUnsupportedExtInst —
    // a needless honest-error for an op WGSL fully supports as firstLeadingBit.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { uint a; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ uint m = uint(findMSB(u.a)); o = vec4(float(m)); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "firstLeadingBit(");
    try nagaValidateOrSkip(wgsl, "findMSB-uint");
}

// textureProj semantics: divide the coordinate by its LAST component, then
// sample with the leading components matching the sampler dimensionality. WGSL
// has no projective builtin, but the perspective divide + plain textureSample is
// a CORRECT, naga-validated lowering for the non-Dref forms — so emit it
// (dimension-aware), rather than blanket honest-erroring (which regressed the
// working 2D case). Dref/compare projective forms stay honest-errored.
test "wgsl: textureProj(sampler2D, vec4) lowers to coord.xy / coord.w" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProj(tex, vec4(gl_FragCoord.xy, 0.0, 1.0)); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSample(");
    try assertContains(wgsl, ".xy / ");
    try assertContains(wgsl, ".w");
    try nagaValidateOrSkip(wgsl, "textureProj-2d-vec4");
}

test "wgsl: textureProj(sampler2D, vec3) divides by the LAST component (.z)" {
    // The vec3 form's divisor is the LAST component (.z), not .w. The old
    // handler emitted `.w` on a vec3 (out-of-bounds / wrong) — this is the
    // dimension-aware fix.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProj(tex, vec3(gl_FragCoord.xy, 1.0)); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSample(");
    try assertContains(wgsl, ".xy / ");
    try assertContains(wgsl, ".z");
    try nagaValidateOrSkip(wgsl, "textureProj-2d-vec3");
}

test "wgsl: textureProj(sampler3D, vec4) lowers to coord.xyz / coord.w" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler3D tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProj(tex, vec4(gl_FragCoord.xyz, 1.0)); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSample(");
    try assertContains(wgsl, ".xyz / ");
    try assertContains(wgsl, ".w");
    try nagaValidateOrSkip(wgsl, "textureProj-3d-vec4");
}

// #170: textureProjLod (projective sample + EXPLICIT lod) was wrongly rejected
// (honest-error) even though WGSL CAN represent it: perspective-divide the coord
// then textureSampleLevel(t, s, coord/divisor, lod). The frontend now emits
// OpImageSampleProjExplicitLod with the Lod operand; the WGSL backend lowers it.
test "wgsl: textureProjLod(sampler2D, vec4) lowers to textureSampleLevel(coord.xy / .w, lod)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjLod(tex, vec4(gl_FragCoord.xy, 0.0, 1.0), 2.0); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSampleLevel(");
    try assertContains(wgsl, ".xy / ");
    try assertContains(wgsl, ".w");
    try nagaValidateOrSkip(wgsl, "textureProjLod-2d-vec4");
}

test "wgsl: textureProjLod(sampler2D, vec3) divides by the LAST component (.z)" {
    // The vec3 form's divisor is the LAST component (.z), not .w — same
    // dimension-aware rule as textureProj.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = textureProjLod(tex, vec3(gl_FragCoord.xy, 1.0), 1.0); }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSampleLevel(");
    try assertContains(wgsl, ".xy / ");
    try assertContains(wgsl, ".z");
    try nagaValidateOrSkip(wgsl, "textureProjLod-2d-vec3");
}

test "wgsl: projective shadow (sampler2DShadow) lowers to a projective compare" {
    // Projective depth-compare HAS a faithful lowering: textureProj divides both
    // the coordinate and the depth reference by the coordinate's last component,
    // so textureProj(sampler2DShadow, P) → textureSampleCompare(t, s, P.xy / P.w,
    // P.z / P.w). (Was previously honest-errored; #170.) Uses glslpp's OWN frontend
    // — a different SPIR-V producer than the glslang-based test above, covering the
    // OpCompositeInsert coordinate-packing both emit.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0) uniform sampler2DShadow tex;
        \\layout(location=0) out float o;
        \\void main(){ o = textureProj(tex, vec4(gl_FragCoord.xy, 0.5, 1.0)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSampleCompare(");
    try assertContains(wgsl, ".xy /");
    // The perspective divide must apply to BOTH coord and depth ref (same divisor
    // appears at least twice in the call).
    try std.testing.expect(std.mem.count(u8, wgsl, " / ") >= 2);
    try nagaValidateOrSkip(wgsl, "proj-shadow-frontend");
}

test "wgsl: fragment-shader interlock is an honest error (no WGSL equivalent)" {
    // GL_ARB_fragment_shader_interlock emits OpBeginInvocationInterlockEXT /
    // OpEndInvocationInterlockEXT (and an interlock execution mode). WGSL has no
    // fragment-shader interlock; fail loud rather than silently drop the barrier.
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_ARB_fragment_shader_interlock : require
        \\layout(pixel_interlock_ordered) in;
        \\layout(binding=0, std430) buffer B { uint counter; };
        \\layout(location=0) out vec4 o;
        \\void main(){ beginInvocationInterlockARB(); counter += 1u; endInvocationInterlockARB(); o = vec4(1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

test "wgsl: the main-path else no longer emits a silent-wrong placeholder var" {
    // Regression guard for the silent-wrong `else` fallback. It used to emit
    // `// unhandled op N` + `var <name>: T;` (an uninitialized var = garbage value
    // that naga still accepts). A representative shader exercising many ops must
    // compile WITHOUT any such placeholder, and naga must accept the real output.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { vec4 a; vec4 b; uint n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\    vec4 m = mix(u.a, u.b, 0.5);
        \\    uint bits = uint(findMSB(u.n)) + uint(findLSB(u.n));
        \\    o = m + vec4(float(bits)) + vec4(min(u.a.x, u.b.x), max(u.a.y, u.b.y), clamp(u.a.z, 0.0, 1.0), 1.0);
        \\}
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    try assertNotContains(wgsl, "unhandled op");
    try nagaValidateOrSkip(wgsl, "no-silent-placeholder");
}

test "wgsl: matrix-element const-array global folds to an mat4x4 array initializer (#173 item1)" {
    // #173 item1: `const mat4 M[2]` runtime-indexed. The frontend now folds the
    // matrix ctors + the array ctor to OpConstantComposite, so M carries an
    // initializer the WGSL backend materializes as an `array<mat4x4f, 2>(...)`
    // (or const) — not an undeclared/garbage global. naga is the ground truth.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 FragColor;
        \\const mat4 M[2] = mat4[](mat4(1.0), mat4(2.0));
        \\void main(){
        \\  int i = int(gl_FragCoord.x) & 1;
        \\  FragColor = M[i] * vec4(1.0);
        \\}
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    // The array is materialized as a mat4x4 array with an initializer (the exact
    // var<private>/const spelling may vary). Assert the constructor SHAPE with the
    // folded diagonal values (like the MSL test asserts `float4x4(float4(…))`), not
    // just a bare "2.0" substring — proves the matrix ctors actually folded.
    try assertContains(wgsl, "array<mat4x4");
    try assertContains(wgsl, "mat4x4f(vec4f(1.0, 0.0, 0.0, 0.0)");
    try assertContains(wgsl, "mat4x4f(vec4f(2.0, 0.0, 0.0, 0.0)");
    try nagaValidateOrSkip(wgsl, "matrix-const-array-#173");
}

// ---------------------------------------------------------------------------
// Pass 2 (#170 G5): OpOuterProduct → matrix construction.
// outerProduct(u, v) (u is an R-vector, v is a C-vector) yields a CxR matrix
// whose column i is u*v[i]. WGSL has no outerProduct builtin; the backend must
// construct the matrix explicitly. Previously OpOuterProduct fell through to the
// honest-error else-arm. naga is the ground truth.
// ---------------------------------------------------------------------------

test "wgsl: outerProduct(vec3,vec3) builds a mat3x3 (naga-validated)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec3 a;
        \\layout(location=1) in vec3 b;
        \\layout(location=0) out vec4 o;
        \\void main(){ mat3 m = outerProduct(a, b); o = vec4(m[0], 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "mat3x3") != null);
    try nagaValidateOrSkip(wgsl, "outerProduct-mat3");
}

test "wgsl: outerProduct(vec2,vec2) builds a mat2x2 (naga-validated)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec2 a;
        \\layout(location=1) in vec2 b;
        \\layout(location=0) out vec4 o;
        \\void main(){ mat2 m = outerProduct(a, b); o = vec4(m[0], m[1]); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "mat2x2") != null);
    try nagaValidateOrSkip(wgsl, "outerProduct-mat2");
}

test "wgsl: outerProduct(vec4,vec2) builds a non-square mat2x4 (naga-validated)" {
    // u is a 4-vector (rows), v is a 2-vector (cols) → a 2-column, 4-row matrix
    // (WGSL mat2x4). The result has v's column count and u's row count.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) in vec4 a;
        \\layout(location=1) in vec2 b;
        \\layout(location=0) out vec4 o;
        \\void main(){ mat2x4 m = outerProduct(a, b); o = m[0] + m[1]; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "mat2x4") != null);
    try nagaValidateOrSkip(wgsl, "outerProduct-mat2x4");
}

// ---------------------------------------------------------------------------
// Pass 2 (#170 G5): abstract scalar-literal typing.
// naga rejects all-constant-arg builtin calls (e.g. smoothstep(0.08, 0.03, 1.0))
// with "Abstract types may only appear in constant expressions". Suffixing scalar
// float constants with `f` types them concretely, which naga accepts.
// ---------------------------------------------------------------------------

test "wgsl: all-constant smoothstep is naga-valid (abstract-literal typing)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ float t = smoothstep(0.08, 0.03, 1.0); o = vec4(t); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // A scalar float constant must be typed (e.g. `0.08f`) rather than abstract.
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "0.08f") != null);
    try nagaValidateOrSkip(wgsl, "abstract-smoothstep");
}

test "wgsl: all-constant mix is naga-valid (abstract-literal typing)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\void main(){ float t = mix(0.25, 0.75, 0.5); o = vec4(t); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "abstract-mix");
}

// ---------------------------------------------------------------------------
// Pass 2 (#170 G5) AUDIT FIX: subgroup ops were emitted directly (e.g.
// subgroupElect()) with NO `enable subgroups;`. naga 29.0.3 rejects subgroups
// entirely, so this was silent-wrong. They must now honest-error.
// ---------------------------------------------------------------------------

test "wgsl: subgroupElect errors honestly (WGSL/naga has no subgroups)" {
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_KHR_shader_subgroup_basic : require
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(subgroupElect() ? 1.0 : 0.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "subgroup") != null);
}

// ---------------------------------------------------------------------------
// Pass 2 (#170 G5) AUDIT FIX: image atomics emitted atomicAdd(&textureLoad(...))
// which naga rejects ("operand of & must be a reference"). WGSL has no image
// atomics; the OpAtomic* handler must honest-error when the pointer resolves to
// an image / textureLoad.
// ---------------------------------------------------------------------------

test "wgsl: image atomic errors honestly (WGSL has no image atomics)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, r32ui) uniform uimage2D img;
        \\layout(location=0) out vec4 o;
        \\void main(){ uint old = imageAtomicAdd(img, ivec2(0,0), 1u); o = vec4(float(old)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "image atomic") != null);
}

// ---------------------------------------------------------------------------
// Pass 3 (#170 G5) ITEM A1: push-constant blocks. SPIR-V StorageClass
// PushConstant was unhandled (fell into the switch `else`), so the struct type
// and the `push` var were never emitted while the body still referenced
// `push.a` → naga "no definition in scope for push". WGSL has no push_constant
// address space (naga 29.0.3 rejects both `var<push_constant>` and
// `enable push_constant`); the representable lowering is a uniform buffer.
// ---------------------------------------------------------------------------

test "wgsl: push_constant block lowers to var<uniform>" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(push_constant) uniform PC { vec4 a; vec4 b; } push;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = push.a + push.b; }
    ;
    const wgsl = try compileToWgsl(source);
    defer alloc.free(wgsl);
    // The push-constant block must materialise as a uniform buffer + struct, not
    // vanish (which left `push.a` dangling).
    try assertContains(wgsl, "var<uniform>");
    try assertContains(wgsl, "struct");
    try nagaValidateOrSkip(wgsl, "push-constant-as-uniform");
}

// ---------------------------------------------------------------------------
// Pass 3 (#170 G5) ITEM H: texel buffers. An OpTypeImage with Dim=Buffer
// (GLSL samplerBuffer/imageBuffer) was emitted as `texture_buffer<f32>`, which
// is NOT standard WGSL — naga rejects it (silent-wrong-shaped emission). WGSL
// has no texel-buffer type, so it must honest-error.
// ---------------------------------------------------------------------------

test "wgsl: texel buffer errors honestly (WGSL has no texture_buffer type)" {
    const source: [:0]const u8 =
        \\#version 310 es
        \\#extension GL_OES_texture_buffer : require
        \\layout(binding = 4) uniform highp samplerBuffer uSamp;
        \\void main(){ gl_Position = texelFetch(uSamp, 10); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "texel buffer") != null);
}

// ---------------------------------------------------------------------------
// Pass 4 (#170 G5) sub-bucket A2: array-member-in-uniform stride.
// A uniform (std140) block with a scalar- or vec2-element array member emits
// `array<f32,N>` (stride 4) / `array<vec2<f32>,N>` (stride 8). WGSL's uniform
// address space requires every array element stride to be a multiple of 16, so
// naga REJECTS: "array stride 4 is not a multiple of the required alignment 16".
// `@stride` is not valid WGSL, so the only portable lowering is to widen the
// element to a vec4 and swizzle on access: `arr: array<vec4<f32>,N>` + `.x`.
// vec4/mat array members are already 16-aligned and must NOT be wrapped.
// Storage (SSBO) tolerates stride 4 → UNIFORM-ONLY.
// ---------------------------------------------------------------------------

test "wgsl: A2 scalar array member in uniform wrapped as array<vec4>+.x" {
    // RED (before fix): naga "array stride 4 is not a multiple of the required
    //  alignment 16" on `arr: array<f32, 4>`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { float arr[4]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.arr[u.n], 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The scalar-element array member is widened to vec4<f32>.
    try assertContains(wgsl, "array<vec4<f32>, 4>");
    // Access site swizzles the widened element back to a scalar.
    try assertContains(wgsl, ".x");
    try nagaValidateOrSkip(wgsl, "A2-scalar-array");
}

test "wgsl: A2 vec2 array member in uniform wrapped as array<vec4>+.xy" {
    // RED (before fix): naga "array stride 8 is not a multiple of the required
    //  alignment 16" on `arr: array<vec2<f32>, 4>`.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { vec2 arr[4]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.arr[u.n], 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "array<vec4<f32>, 4>");
    try assertContains(wgsl, ".xy");
    try nagaValidateOrSkip(wgsl, "A2-vec2-array");
}

test "wgsl: A2 mixed block — scalar array wrapped, vec4 array NOT wrapped" {
    // A block mixing a sub-16 scalar array (must wrap+.x) with already-16-aligned
    // members (mat4, vec4 array, vec4 scalar) which must be emitted verbatim.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U {
        \\  float sarr[3];
        \\  mat4 m;
        \\  vec4 v4[2];
        \\  vec4 off;
        \\  int n;
        \\} u;
        \\layout(location=0) out vec4 o;
        \\void main(){
        \\  o = vec4(u.sarr[u.n], 0.0, 0.0, 1.0) + u.m[0] + u.v4[u.n] + u.off;
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The scalar array member is widened to vec4<f32>.
    try assertContains(wgsl, "array<vec4<f32>, 3>");
    // The vec4 array member stays the normal shorthand (already 16-aligned).
    try assertContains(wgsl, "v4: array<vec4f, 2>");
    // It must NOT be re-widened, and its access must NOT carry a stray swizzle.
    try assertNotContains(wgsl, "v4: array<vec4<f32>, 2>");
    try assertNotContains(wgsl, "v4[u.n].x");
    try nagaValidateOrSkip(wgsl, "A2-mixed");
}

test "wgsl: A2 regression — array-of-vec4 uniform stays unwrapped, no swizzle" {
    // Over-wrap guard: a vec4 array member is already 16-aligned and must be
    // emitted as array<vec4<f32>,3> with NO appended swizzle on access.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { vec4 a[3]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = u.a[u.n]; }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Already-aligned vec4 array stays the normal shorthand (NOT re-widened).
    try assertContains(wgsl, "array<vec4f, 3>");
    try assertNotContains(wgsl, "array<vec4<f32>, 3>");
    // No swizzle should be appended to the vec4-array access.
    try assertNotContains(wgsl, "a[u.n].x");
    try nagaValidateOrSkip(wgsl, "A2-vec4-array");
}

test "wgsl: A2 SSBO scalar array member NOT wrapped (uniform-only gate)" {
    // Gate guard: storage buffers tolerate stride 4, so an SSBO scalar array
    // member must stay array<f32,4> with no swizzle.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std430) buffer B { float arr[4]; int n; } b;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(b.arr[b.n], 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // SSBO scalar array stays a plain f32 array — NOT widened.
    try assertContains(wgsl, "array<f32, 4>");
    try assertNotContains(wgsl, "arr: array<vec4<f32>, 4>");
    try nagaValidateOrSkip(wgsl, "A2-ssbo-scalar-array");
}

// ---------------------------------------------------------------------------
// #170 review — wrap must gate on ArrayStride == 16, NOT just !is_ssbo.
//
// The vec4-wrap (`array<vec4<f32>,N>` + `.x`) is only VALUE-CORRECT when the
// source array's std140 ArrayStride is 16: std140 rounds every array-element
// stride up to 16, so the host packs the float at byte 0 of each 16-byte slot,
// exactly where `arr[i].x` reads it. A scalar-block-layout / std430 UNIFORM
// has ArrayStride 4 (host packs floats tightly at 0,4,8,12); the vec4-wrap then
// reads bytes 0,16,32,48 → WRONG DATA, yet naga ACCEPTS it (silent-wrong).
//
// On `main` this same shader emitted `array<f32,4>` (stride 4) which naga
// REJECTS loudly ("array stride 4 is not a multiple of the required alignment
// 16"). The A2 fix gated the wrap on ArrayStride==16 so the scalar-layout case
// is NOT silently widened to wrong data. But emitting the naga-rejected
// `array<f32,4>` at exit 0 is ITSELF the #170 silent-wrong the sweep targets
// ("naga REJECT = a divergence to fix; honest-unsupported = acceptable"). So the
// scalar-layout / std430 UNIFORM case now HONEST-ERRORS instead of falling
// through to naga-rejected output (uniformBlockHasUnrepresentableSub16Array).
// ---------------------------------------------------------------------------

test "wgsl: A2 scalar-block-layout uniform honest-errors, not silently wrapped (#170)" {
    // The MAJOR silent-wrong guard. The source SPIR-V has ArrayStride 4 (verified
    // out-of-band via spirv-dis: `OpDecorate %_arr_float_uint_4 ArrayStride 4`),
    // so wrapping to `array<vec4<f32>>` + `.x` would read the wrong host bytes,
    // and emitting `array<f32,4>` (stride 4) in uniform space is naga-rejected.
    // Neither is representable → honest-error (the wrap was never recorded since
    // stride != 16; the unrepresentable block is now caught before emission).
    const source: [:0]const u8 =
        \\#version 450
        \\#extension GL_EXT_scalar_block_layout : require
        \\layout(binding=0, scalar) uniform U { float arr[4]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.arr[u.n], 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.MissingErrorDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "stride") != null);
}

test "wgsl: A2 std140 uniform still wraps at ArrayStride 16 (#170 review regression)" {
    // Regression for the stride gate: an std140 uniform float-array member has
    // ArrayStride 16 (verified: `OpDecorate %_arr_float_uint_4 ArrayStride 16`),
    // so it MUST still be wrapped to `array<vec4<f32>>` + `.x` and naga-validate.
    const source: [:0]const u8 =
        \\#version 450
        \\layout(binding=0, std140) uniform U { float arr[4]; int n; } u;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = vec4(u.arr[u.n], 0.0, 0.0, 1.0); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // std140 stride 16 → still widened + swizzled (value-correct).
    try assertContains(wgsl, "array<vec4<f32>, 4>");
    try assertContains(wgsl, ".x");
    try nagaValidateOrSkip(wgsl, "A2-std140-stride16-wrap");
}

// ---------------------------------------------------------------------------
// WGSL undefined-identifier (def-drop) sweep — 6 distinct root causes that each
// left an emitted identifier undeclared (naga "no definition in scope"). Each
// test reproduces one and asserts the fix + naga validity.
// ---------------------------------------------------------------------------

test "wgsl: module-scope struct-array global forward-declares its struct" {
    // A Private global whose element type is a struct (`array<Foo, N>`) was
    // emitted without `struct Foo { … }` — the struct scan only covered
    // Function-scope vars. naga: "no definition in scope for identifier: Foo".
    const src: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\struct Foo { float a; float b; };
        \\Foo foos[2] = Foo[](Foo(10.0, 20.0), Foo(30.0, 40.0));
        \\layout(location = 0) flat in int idx;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(foos[idx].a + foos[1 - idx].b); }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "struct Foo");
    try nagaValidateOrSkip(wgsl, "private struct-array global");
}

test "wgsl: input built-in read in a helper is bridged to var<private>" {
    // gl_FragCoord is `@builtin(position)` — an entry-param only. A helper that
    // reads it referenced an out-of-scope identifier. Bridge it (like @location
    // inputs) to a module-scope var<private> copied from the renamed entry param.
    // Uses the witness fixture: glslpp inlines a trivial helper, collapsing the
    // cross-function pattern, but raymarch_simple's scene() is preserved.
    const wgsl = try compileFileToWgsl("tests/spirv-cross/raymarch_simple.frag");
    defer alloc.free(wgsl);
    try assertContains(wgsl, "var<private> gl_FragCoord");
    try assertContains(wgsl, "gl_FragCoord_in");
    try nagaValidateOrSkip(wgsl, "gl_FragCoord-in-helper bridge");
}

test "wgsl: stage output written in a helper is promoted to var<private>" {
    // An output written only inside non-entry functions referenced an identifier
    // that existed only as main's local `var`. Promote it to a module-scope
    // var<private> (mirror of the input bridge); the entry returns it by name.
    // Witness fixture (its func0/func1/func2 write the output `ov`).
    const wgsl = try compileFileToWgsl("tests/spirv-cross/shader-debug-info-line-directives.line.gV.frag");
    defer alloc.free(wgsl);
    try assertContains(wgsl, "var<private> ov");
    try nagaValidateOrSkip(wgsl, "cross-function output promotion");
}

test "wgsl: loop-header phi classifies init/update by label, not position" {
    // SPIR-V does not fix the order of an OpPhi's (value, label) pairs. The old
    // code hardcoded words[3]=init / words[5]=update; when glslang emitted them
    // reversed, the loop var was initialized from the not-yet-defined back-edge
    // increment → `var v52 = v56;` with v56 undeclared. Inline the exact fixture
    // whose last loop trips this.
    const src: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out int FragColor;
        \\void main() {
        \\   FragColor = 16;
        \\   for (int i = 0; i < 25; i++) FragColor += 10;
        \\   for (int i = 1, j = 4; i < 30; i++, j += 4) FragColor += 11;
        \\   int k = 0;
        \\   for (; k < 20; k++) FragColor += 12;
        \\   k += 3; FragColor += k;
        \\   int m = 0; m = k; int o = m;
        \\   for (; m < 40; m++) FragColor += m;
        \\   FragColor += o;
        \\}
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "loop phi pair classification");
}

test "wgsl: MRT output read-back declares locals and preserves the increment" {
    // A multiple-render-target output read back / partially written (`vo0.x +=`)
    // hit the simple-MRT path that declares no var and returns captured store
    // values — leaving `vo0` undeclared AND dropping the increment (silent-wrong).
    // The fix declares real local vars, emits the stores, and returns the locals.
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 v;
        \\layout(location = 0) out vec4 vo0;
        \\layout(location = 1) out vec4 vo1;
        \\void main() { vo0 = v; vo1 = v; vo0.x += 1.0; vo1.x += 2.0; }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "var vo0");
    try assertContains(wgsl, "return FragmentOutput(vo0, vo1)");
    try nagaValidateOrSkip(wgsl, "MRT output read-back");
}

test "wgsl: Vulkan separate sampler is declared and combined per call site" {
    // A standalone `uniform sampler uS;` (no implicit texture partner) was never
    // declared, and the sampler argument was synthesized as `<tex>_sampler`
    // instead of the real separate sampler — both an undefined identifier and a
    // silent-wrong (a sampler param was ignored). Declare `var uS: sampler;` and
    // route the sampler from the OpSampledImage's sampler operand.
    const src: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(set = 0, binding = 0) uniform mediump sampler uS;
        \\layout(set = 0, binding = 1) uniform mediump texture2D uT;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\vec4 f(mediump texture2D t) { return texture(sampler2D(t, uS), uv); }
        \\void main() { o = f(uT); }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "var uS: sampler");
    try nagaValidateOrSkip(wgsl, "Vulkan separate sampler");
}

test "wgsl: combined sampler2DShadow emits sampler_comparison + textureSampleCompare" {
    // A COMBINED shadow sampler global (no call-site OpSampledImage) must keep
    // working: the texture's implicit `<tex>_sampler` partner is a
    // sampler_comparison and the depth read uses textureSampleCompare.
    const src: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2DShadow uShadow;
        \\layout(location = 0) out float o;
        \\void main() { o = texture(uShadow, vec3(0.5)); }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "sampler_comparison");
    try assertContains(wgsl, "textureSampleCompare");
    try nagaValidateOrSkip(wgsl, "combined sampler2DShadow");
}

test "wgsl: separate comparison sampler is an honest error (unrepresentable)" {
    // `sampler2DShadow(tex, samp)` from a distinct texture + samplerShadow pins
    // depth-ness to the SAMPLE op, but WGSL pins it to the TEXTURE type — and the
    // texture is routinely also sampled non-compare, so a single binding cannot be
    // both texture_depth_2d and texture_2d<f32>. Must fail loud (error.UnsupportedOp),
    // never emit an undeclared `<tex>_sampler` (naga reject) or wrong types.
    const src: [:0]const u8 =
        \\#version 310 es
        \\precision mediump float;
        \\layout(set = 0, binding = 0) uniform mediump samplerShadow uS;
        \\layout(set = 0, binding = 1) uniform texture2D uT;
        \\layout(location = 0) out float o;
        \\void main() { o = texture(sampler2DShadow(uT, uS), vec3(0.5)); }
    ;
    try std.testing.expectError(error.UnsupportedOp, compileToWgsl(src));
}

// #170 (A3): a GLSL `in Inputs { … } vin;` stage-input interface block must emit
// the struct EXACTLY ONCE — as the @location-decorated entry-parameter struct.
// Previously the whole-struct `OpLoad %Inputs %vin` in the body also triggered a
// plain (un-decorated) `struct Inputs { … }` forward-decl, so glslpp emitted the
// type twice and naga rejected the WGSL with "redefinition of `Inputs`".
test "wgsl: stage-input interface block struct is emitted once (no redefinition)" {
    const src: [:0]const u8 =
        \\#version 310 es
        \\precision highp float;
        \\struct Inputs { vec4 a; vec2 b; };
        \\layout(location = 0) in Inputs vin;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    Inputs v0 = vin;
        \\    FragColor = v0.a + v0.b.xxyy + vin.a;
        \\}
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    // The struct name must appear in exactly one `struct Inputs {` definition.
    var count: usize = 0;
    var idx: usize = 0;
    const needle = "struct Inputs {";
    while (std.mem.indexOfPos(u8, wgsl, idx, needle)) |p| {
        count += 1;
        idx = p + needle.len;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try nagaValidateOrSkip(wgsl, "stage-input interface block (no redefinition)");
}

// #170 (A3) DUAL-USE GUARD: a struct used BOTH as a stage-input interface block
// AND as a UBO data member must NOT be de-duplicated by the redefinition fix —
// suppressing the plain decl would leave the uniform referencing a struct whose
// only definition carries @location, which the naga CLI leniently accepts but
// Tint/Dawn reject (a silent-wrong). The fix detects the dual use and keeps the
// prior LOUD behavior (both decls emitted → naga "redefinition" reject) rather
// than emit silently-wrong @location-on-uniform. A full fix (renamed IO struct)
// is deferred. This test pins that the guard fires: the plain data decl survives
// alongside the @location IO decl (two `struct Inputs {`), so glslpp never emits
// the lenient-but-wrong single-struct form.
test "wgsl: struct used as both interface block and UBO member is not silently merged" {
    const src: [:0]const u8 =
        \\#version 310 es
        \\precision highp float;
        \\struct Inputs { vec4 a; vec2 b; };
        \\layout(location = 0) in Inputs vin;
        \\layout(binding = 0) uniform UBO { Inputs u; } ubo;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() { FragColor = vin.a + ubo.u.a + vin.b.xxyy; }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    var count: usize = 0;
    var idx: usize = 0;
    const needle = "struct Inputs {";
    while (std.mem.indexOfPos(u8, wgsl, idx, needle)) |p| {
        count += 1;
        idx = p + needle.len;
    }
    // Dual-use is NOT de-duplicated (the plain data decl is preserved): the
    // @location version is not allowed to stand in for the uniform's data type.
    try std.testing.expectEqual(@as(usize, 2), count);
}

// #170 (B): GLSL `textureQueryLevels` returns a SIGNED `int`, but WGSL
// `textureNumLevels` returns `u32`. glslpp annotates the `let` with the GLSL
// (signed) result type, so emitting the bare builtin left `let v: i32 =
// textureNumLevels(t);` — naga rejects ("type of `v` is expected to be `i32`,
// but got `u32`"). The result must be wrapped `i32(textureNumLevels(t))`, just
// like the ImageQuerySize (textureDimensions) path already does.
test "wgsl: textureQueryLevels result is converted to the signed GLSL type" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D uSampler;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    int lv = textureQueryLevels(uSampler);
        \\    o = vec4(float(lv));
        \\}
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "i32(textureNumLevels(");
    try nagaValidateOrSkip(wgsl, "textureQueryLevels signed result");
}

// #170 (B): GLSL `textureSamples` returns a SIGNED `int`; WGSL
// `textureNumSamples` returns `u32`. Same signed-conversion requirement.
test "wgsl: textureSamples result is converted to the signed GLSL type" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2DMS uMS;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    int ns = textureSamples(uMS);
        \\    o = vec4(float(ns));
        \\}
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "i32(textureNumSamples(");
    try nagaValidateOrSkip(wgsl, "textureSamples signed result");
}

// #170 (E): a storage image's WGSL texel format was hardcoded to `rgba8unorm`
// (a float format) regardless of the GLSL `layout(...)` format qualifier, so an
// `r32i` (signed-int) image emitted `texture_storage_2d<rgba8unorm, …>` and its
// `textureLoad` returned `vec4<f32>` — but the result was annotated `vec4<i32>`,
// so naga rejected ("expected vec4<i32>, got vec4<f32>"). The texel format must
// be derived from the SPIR-V ImageFormat operand: `r32i` → `r32sint`.
test "wgsl: storage image texel format follows the GLSL format qualifier (r32i)" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(r32i, binding = 0) uniform readonly iimage2D uImage;
        \\layout(location = 0) out vec4 o;
        \\void main() { ivec4 v = imageLoad(uImage, ivec2(10)); o = vec4(v); }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "r32sint");
    try assertNotContains(wgsl, "rgba8unorm");
    try nagaValidateOrSkip(wgsl, "storage image r32i format");
}

// #170 (E): r32f stays a float format (rgba8unorm was wrong even for floats —
// the channel count differs); rgba32f → rgba32float; r32ui → r32uint.
test "wgsl: storage image texel format follows r32f / rgba32f / r32ui" {
    const r32f: [:0]const u8 =
        \\#version 450
        \\layout(r32f, binding = 0) uniform readonly image2D uImage;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = imageLoad(uImage, ivec2(3)); }
    ;
    const wf = try compileToWgsl(r32f);
    defer alloc.free(wf);
    try assertContains(wf, "r32float");
    try nagaValidateOrSkip(wf, "storage image r32f format");

    const rgba32ui: [:0]const u8 =
        \\#version 450
        \\layout(rgba32ui, binding = 0) uniform readonly uimage2D uImage;
        \\layout(location = 0) out vec4 o;
        \\void main() { uvec4 v = imageLoad(uImage, ivec2(3)); o = vec4(v); }
    ;
    const wu = try compileToWgsl(rgba32ui);
    defer alloc.free(wu);
    try assertContains(wu, "rgba32uint");
    try nagaValidateOrSkip(wu, "storage image rgba32ui format");
}

// #217 review [MINOR]: storage textures were always emitted with access mode
// `read_write`, ignoring the GLSL `readonly` / `writeonly` qualifiers (which
// lower to SPIR-V NonWritable / NonReadable decorations on the image variable).
// A `readonly image2D` must emit `…, read>` and a `writeonly image2D` must emit
// `…, write>` — `write` is core-WGSL while `read`/`read_write` need the
// readonly_and_readwrite_storage_textures language feature, so emitting
// read_write for a writeonly image is needlessly less portable (Dawn/wgpu).
test "wgsl: readonly storage image emits read access mode (NonWritable)" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(r32i, binding = 0) uniform readonly iimage2D uImage;
        \\layout(location = 0) out vec4 o;
        \\void main() { ivec4 v = imageLoad(uImage, ivec2(10)); o = vec4(v); }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "texture_storage_2d<r32sint, read>");
    try assertNotContains(wgsl, "read_write");
    try nagaValidateOrSkip(wgsl, "readonly storage image read access");
}

// #217 review [MINOR]: a `writeonly` image lowers to NonReadable and must emit
// the `write` access mode — the only core-WGSL storage access.
test "wgsl: writeonly storage image emits write access mode (NonReadable)" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(rgba8, binding = 0) uniform writeonly image2D uImage;
        \\layout(location = 0) out vec4 o;
        \\void main() { imageStore(uImage, ivec2(3), vec4(1.0)); o = vec4(0.0); }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "texture_storage_2d<rgba8unorm, write>");
    try assertNotContains(wgsl, "read_write");
    try nagaValidateOrSkip(wgsl, "writeonly storage image write access");
}

// #217 review [MAJOR]: NonWritable/NonReadable are valid (per spirv-val) only on
// storage images and buffers. glslpp — unlike glslang, which rejects
// `readonly sampler2D` — does NOT reject memory qualifiers on a combined
// sampler, so the frontend gate that emits these decorations must fire only for
// storage IMAGES, never for any uniform_constant resource. A too-broad gate
// decorated the sampler variable with NonWritable, which spirv-val rejects
// ("Target of NonWritable decoration is invalid: must point to a storage
// image…"). The bogus qualifier must be silently ignored (as it was before).
test "wgsl: readonly/writeonly on a non-storage-image sampler emits no NonWritable/NonReadable" {
    const ro: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform readonly sampler2D uTex;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = texture(uTex, vec2(0.5)); }
    ;
    const ro_spv = try glslpp.compileToSPIRV(alloc, ro, .{ .stage = .fragment });
    defer alloc.free(ro_spv);
    try std.testing.expect(!spirvHasDecoration(ro_spv, 24)); // NonWritable
    try std.testing.expect(!spirvHasDecoration(ro_spv, 25)); // NonReadable

    const wo: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform writeonly sampler2D uTex;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = texture(uTex, vec2(0.5)); }
    ;
    const wo_spv = try glslpp.compileToSPIRV(alloc, wo, .{ .stage = .fragment });
    defer alloc.free(wo_spv);
    try std.testing.expect(!spirvHasDecoration(wo_spv, 24)); // NonWritable
    try std.testing.expect(!spirvHasDecoration(wo_spv, 25)); // NonReadable
}

// #217 review: conversely, a real `readonly` / `writeonly` storage image MUST
// carry NonWritable / NonReadable in the emitted SPIR-V — this is the decoration
// the WGSL backend reads to pick the read / write access mode. Asserts the
// frontend half of the fix directly at the SPIR-V level.
test "wgsl: readonly/writeonly storage image emits NonWritable/NonReadable in SPIR-V" {
    const ro: [:0]const u8 =
        \\#version 450
        \\layout(r32f, binding = 0) uniform readonly image2D uImage;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = imageLoad(uImage, ivec2(0)); }
    ;
    const ro_spv = try glslpp.compileToSPIRV(alloc, ro, .{ .stage = .fragment });
    defer alloc.free(ro_spv);
    try std.testing.expect(spirvHasDecoration(ro_spv, 24)); // NonWritable present
    try std.testing.expect(!spirvHasDecoration(ro_spv, 25)); // but not NonReadable

    const wo: [:0]const u8 =
        \\#version 450
        \\layout(rgba8, binding = 0) uniform writeonly image2D uImage;
        \\layout(location = 0) out vec4 o;
        \\void main() { imageStore(uImage, ivec2(0), vec4(1.0)); o = vec4(0.0); }
    ;
    const wo_spv = try glslpp.compileToSPIRV(alloc, wo, .{ .stage = .fragment });
    defer alloc.free(wo_spv);
    try std.testing.expect(spirvHasDecoration(wo_spv, 25)); // NonReadable present
    try std.testing.expect(!spirvHasDecoration(wo_spv, 24)); // but not NonWritable
}

// #170 (C): textureSize on an ARRAYED sampler must combine the spatial dims
// (WGSL textureDimensions — vec2 for 2D/cube) with the layer count (WGSL
// textureNumLayers), because GLSL textureSize(sampler2DArray) returns ivec3
// (w,h,layers) while WGSL textureDimensions returns only vec2<u32>. The old code
// emitted `vec3i(textureDimensions(t))` — naga: "cannot cast a vec2<u32> to a
// vec3<i32>". Correct lowering: vec3<i32>(vec2<i32>(textureDimensions(t)),
// i32(textureNumLayers(t))).
test "wgsl: textureSize on 2D-array / cube-array appends textureNumLayers" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2DArray s2a;
        \\layout(binding = 1) uniform samplerCubeArray sca;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec3 a = textureSize(s2a, 0);
        \\    ivec3 b = textureSize(sca, 0);
        \\    o = vec4(float(a.x + a.y + a.z + b.x + b.y + b.z));
        \\}
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureNumLayers(s2a)");
    try assertContains(wgsl, "textureNumLayers(sca)");
    try nagaValidateOrSkip(wgsl, "arrayed textureSize layer count");
}

// #170 (C): a NON-arrayed textureSize stays the plain dimension wrap (no
// textureNumLayers) — guards against over-applying the arrayed path.
test "wgsl: textureSize on a non-arrayed 2D sampler stays a plain dimension query" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s2;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec2 a = textureSize(s2, 0);
        \\    o = vec4(float(a.x + a.y));
        \\}
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertNotContains(wgsl, "textureNumLayers");
    try nagaValidateOrSkip(wgsl, "non-arrayed textureSize");
}

// #170 (C, review follow-up): WGSL has NO 1D-array texture type
// (`texture_1d_array` is not a real WGSL type). A GLSL sampler1DArray must fail
// LOUD (error.UnsupportedOp) rather than emit an invalid type name that naga
// rejects downstream — mirroring the storage 1D-array and texel-buffer guards.
test "wgsl: sampler1DArray is an honest error (WGSL has no 1D-array texture)" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(binding = 0) uniform sampler1DArray t;
        \\layout(location = 0) out vec4 o;
        \\void main() { ivec2 s = textureSize(t, 0); o = vec4(float(s.x + s.y)); }
    ;
    try std.testing.expectError(error.UnsupportedOp, compileToWgsl(src));
}

// #170 (H): WGSL forbids a matrix at a single @location — a vertex `out mat4`
// must be flattened into N consecutive @location vecN members (one per column),
// and each whole-matrix store split into per-column writes. The old code emitted
// `@location(1) M: mat4x4f` which naga rejects.
test "wgsl: vertex out mat4 is flattened into 4 vec4 @location members" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec4 P;
        \\layout(location = 1) out mat4 OutM;
        \\void main() { OutM = mat4(2.0); gl_Position = P; }
    ;
    const wgsl = try compileVertToWgsl(src);
    defer alloc.free(wgsl);
    // 4 column members at consecutive locations, all vec4f, no bare mat4 @location.
    try assertContains(wgsl, "@location(1) OutM_0: vec4f");
    try assertContains(wgsl, "@location(4) OutM_3: vec4f");
    try assertNotContains(wgsl, "@location(1) OutM: mat4x4f");
    try nagaValidateOrSkip(wgsl, "vertex mat4 output flattening");
}

// #170 (H): a vertex `out` interface block with an ARRAY member (`out Foo { float
// a[4]; }`) emitted `@location(0) a: array<f32, 4>` — WGSL forbids an array at a
// @location (naga: "only numeric scalars and vectors are allowed"). The array is
// written by a dynamic-index loop (`a[i] = …`), which cannot target separate
// @location members directly. Fix: flatten the array into N scalar @location
// members (`a_0 … a_3`), keep the body writing a reconstructed local nested
// struct (`io_foo.a[i]`), and copy each element out into the flattened members
// before return. Pinned to the corpus fixture.
test "wgsl: vertex out interface-block array member is flattened to per-element @location" {
    const wgsl = try compileFileVertToWgsl("tests/spirv-cross/struct-flatten-inner-array.legacy.vert");
    defer alloc.free(wgsl);
    // 4 scalar members at consecutive locations; no bare array @location.
    try assertContains(wgsl, "@location(0) a_0: f32");
    try assertContains(wgsl, "@location(3) a_3: f32");
    try assertNotContains(wgsl, "a: array<f32, 4>,\n    @location");
    try assertNotContains(wgsl, "@location(0) a: array");
    // Each element copied out of the reconstructed local before return.
    try assertContains(wgsl, "vertex_out.a_0 = io_foo.a[0]");
    try assertContains(wgsl, "vertex_out.a_3 = io_foo.a[3]");
    try nagaValidateOrSkip(wgsl, "vertex array output-member flattening");
}

// #170 (H): the same reassembly path also flattens a vertex `out` block with a
// NESTED-STRUCT member (`out Blk { Mid m; }`, Mid has an Inner struct + a vec4) —
// recursively into leaf @location members (`m_i_x`, `m_y`) copied out of the
// reassembled local. (Bonus coverage of the recursion; no corpus fixture.)
test "wgsl: vertex out interface-block nested-struct member is recursively flattened" {
    const src: [:0]const u8 =
        \\#version 450
        \\struct Inner { vec4 x; };
        \\struct Mid { Inner i; vec4 y; };
        \\out Blk { Mid m; } blk;
        \\void main() { blk.m.i.x = vec4(1.0); blk.m.y = vec4(2.0); gl_Position = vec4(0.0); }
    ;
    const wgsl = try compileVertToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "@location(0) m_i_x: vec4f");
    try assertContains(wgsl, "@location(1) m_y: vec4f");
    try assertContains(wgsl, "vertex_out.m_i_x = io_blk.m.i.x");
    try nagaValidateOrSkip(wgsl, "vertex nested-struct output-member flattening");
}

// #170 (H): a PARTIAL write to one column of a flattened matrix output
// (`M[c] = col;`) can't address the flattened `{base}_{c}` members via an access
// chain, so it fails loud rather than emit naga-invalid `vertex_out.M[c]`.
// (Out-of-corpus deferred sub-case; whole-matrix writes are the supported path.)
test "wgsl: partial matrix-output column write is an honest error" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 1) out mat4 M;
        \\void main() { M[2] = vec4(1.0); gl_Position = vec4(0.0); }
    ;
    try std.testing.expectError(error.UnsupportedOp, compileVertToWgsl(src));
}

// #170 (F): a `shared` (workgroup) scalar that is the target of an atomic op
// must be declared `atomic<u32>` in WGSL, and its NON-atomic accesses lowered to
// atomicStore/atomicLoad. The old code emitted `var<workgroup> s: u32` + a bare
// `atomicAdd(&s, …)` (naga: "atomic operation is done on a pointer to a
// non-atomic") and bare `s = 0u;` / `let v = s;`.
test "wgsl: workgroup atomic scalar is typed atomic<u32> with atomicStore/atomicLoad" {
    const src: [:0]const u8 =
        \\#version 310 es
        \\layout(local_size_x = 32) in;
        \\shared uint s_counter;
        \\layout(std430, binding = 0) buffer Result { uint total; } result;
        \\void main() {
        \\    uint idx = gl_LocalInvocationID.x;
        \\    if (idx == 0u) s_counter = 0u;
        \\    barrier();
        \\    atomicAdd(s_counter, 1u);
        \\    barrier();
        \\    if (idx == 0u) result.total = s_counter;
        \\}
    ;
    const wgsl = try compileCompToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "var<workgroup> s_counter: atomic<u32>");
    try assertContains(wgsl, "atomicStore(&s_counter,");
    try assertContains(wgsl, "atomicLoad(&s_counter)");
    try nagaValidateOrSkip(wgsl, "workgroup atomic scalar");
}

// #170 (H): a whole-matrix store to a flattened matrix output that lands inside
// a `switch` case body is replayed through `emitSimpleInstruction` — a separate
// Store path that has no access to the matrix-output map — so it emitted
// `vertex_out.M = mat4x4f(…)` (naga-invalid: no member `M`, it was flattened to
// `M_0…M_3`). It cannot be split correctly there either: the sibling switch
// `default` case body is dropped entirely (a separate, deeper frontend
// miscompile affecting all backends), so emitting per-column writes would turn
// an honest naga-reject into silent-wrong. Fail loud instead. (Out-of-corpus.)
test "wgsl: matrix-output store inside a switch case is an honest error" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 1) out mat4 OutM;
        \\layout(location = 0) flat in int sel;
        \\void main() {
        \\    switch (sel) {
        \\        case 0: OutM = mat4(2.0); break;
        \\        default: OutM = mat4(3.0); break;
        \\    }
        \\    gl_Position = vec4(1.0);
        \\}
    ;
    try std.testing.expectError(error.UnsupportedOp, compileVertToWgsl(src));
    // Pin the detail so the catch-all UnsupportedOp can't silently start meaning
    // a different unsupported op in this matrix-heavy shader.
    const detail = glslpp.wgslLastErrorDetail() orelse return error.MissingErrorDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "switch") != null);
}

// #170 (J): GL_ARB_shader_stencil_export's gl_FragStencilRef has NO WGSL
// equivalent (WGSL fragment shaders cannot write the stencil ref). It must fail
// loud rather than emit the int stencil value into an auto-assigned @location
// vec4f color output (naga: "cannot convert {AbstractInt} to vec4<f32>").
test "wgsl: gl_FragStencilRef output is an honest error (no WGSL stencil export)" {
    const src: [:0]const u8 =
        \\#version 450
        \\#extension GL_ARB_shader_stencil_export : require
        \\layout(location = 0) out vec4 MRT0;
        \\void main() { MRT0 = vec4(1.0); gl_FragStencilRefARB = 100; }
    ;
    try std.testing.expectError(error.UnsupportedOp, compileToWgsl(src));
}

// #170 (H): GLSL `layout(location=N, component=M)` packs several bindings into
// one location's component slots. WGSL has no @component, so two inputs sharing
// @location(0) is invalid (naga: "Multiple bindings at location 0 are present").
// glslpp does not reconstruct component packing, so it must fail loud rather
// than emit the naga-rejected duplicate-location interface (silent-wrong).
// Pinned to the real corpus fixture (no other driver runs it through the WGSL
// backend), and the detail is asserted so the catch-all UnsupportedOp can't
// silently start meaning a different unsupported op.
test "wgsl: layout(component) duplicate-location inputs are an honest error" {
    try std.testing.expectError(error.UnsupportedOp, compileFileToWgsl("tests/spirv-cross/layout-component.desktop.frag"));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.MissingErrorDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "@component") != null);
}

// Negative control: two inputs at DISTINCT locations must still compile to valid
// WGSL — guards the collision check above from firing over-eagerly.
test "wgsl: inputs at distinct locations still compile (component check control)" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 v0;
        \\layout(location = 1) in float v1;
        \\layout(location = 0) out vec2 FragColor;
        \\void main() { FragColor = v0 + v1; }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "distinct-location inputs control");
}

// #170 (H): a stage-IO interface block whose member is itself a struct
// (`in VertexIn { Foo a; Foo b; }` / `in Baz baz;`) emitted a struct-typed
// `@location` member (`@location(0) a: Foo`) — naga rejects ("only numeric
// scalars and vectors are allowed"). WGSL cannot put a struct at a @location, so
// the block's entry interface is flattened into consecutive leaf @location params
// (`VertexIn_a_a`@0 … `baz_bar_b`@7) and the original nested struct is reassembled
// into a local at body start (`VertexIn(Foo(VertexIn_a_a, …), …)`), leaving the
// body's nested accesses (`io_VertexIn.a.a`) untouched. Pinned to the corpus fixture.
test "wgsl: nested-struct stage-IO members are flattened to leaf @location params" {
    const wgsl = try compileFileToWgsl("tests/spirv-cross/multiple-struct-flattening.legacy.frag");
    defer alloc.free(wgsl);
    // Flattened leaf params at consecutive locations (VertexIn: 0–3; Baz: 4–7).
    try assertContains(wgsl, "@location(0) VertexIn_a_a: vec4f");
    try assertContains(wgsl, "@location(3) VertexIn_b_b: vec4f");
    try assertContains(wgsl, "@location(4) baz_foo_a: vec4f");
    try assertContains(wgsl, "@location(7) baz_bar_b: vec4f");
    // The nested struct is reassembled from the leaf params for the body to use.
    try assertContains(wgsl, "VertexIn(Foo(VertexIn_a_a, VertexIn_a_b)");
    try assertContains(wgsl, "io_baz.foo.a");
    // No struct/array survives at a @location (naga's actual rule).
    try assertNotContains(wgsl, "@location(0) a: Foo");
    try nagaValidateOrSkip(wgsl, "nested-struct IO flattening");
}

// A mid-body early `return` inside an entry function must actually EXIT — the
// void OpReturn used to be dropped ("handled by wrapper"), so the early branch
// fell through to later stage-IO writes and its output was unconditionally
// overwritten (silent-wrong: naga ACCEPTS the miscompiled output). The fix emits
// an explicit `return <output>;` at the early-return point so the branch's value
// survives.
test "wgsl: vertex early return is honored (value preserved, not dropped)" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 col;
        \\layout(location=1) in float cond;
        \\void main() {
        \\    if (cond > 0.0) { col = vec4(10.0); return; }
        \\    col = vec4(20.0);
        \\    gl_Position = vec4(0.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .vertex });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);

    // Semantic, naga-free guard: a `return` MUST appear between the early-branch
    // write (col = 10) and the fall-through write (col = 20). If the return is
    // dropped, the only `return` is the trailing one — after col = 20 — and the
    // 10.0 path is dead.
    const a10 = std.mem.indexOf(u8, wgsl, "vec4<f32>(10.0)") orelse return error.TestExpectedFind;
    const a20 = std.mem.indexOf(u8, wgsl, "vec4<f32>(20.0)") orelse return error.TestExpectedFind;
    const aret = std.mem.indexOfPos(u8, wgsl, a10, "return") orelse return error.TestExpectedFind;
    try std.testing.expect(aret < a20);

    try nagaValidateOrSkip(wgsl, "vertex-early-return");
}

// The simple-fragment form (output accumulates in a single named local that is
// returned by name) must also honor the early return.
test "wgsl: fragment early return is honored (value preserved, not dropped)" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 fragColor;
        \\layout(location=1) in float cond;
        \\void main() {
        \\    if (cond > 0.0) { fragColor = vec4(10.0); return; }
        \\    fragColor = vec4(20.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);

    const a10 = std.mem.indexOf(u8, wgsl, "vec4<f32>(10.0)") orelse return error.TestExpectedFind;
    const a20 = std.mem.indexOf(u8, wgsl, "vec4<f32>(20.0)") orelse return error.TestExpectedFind;
    const aret = std.mem.indexOfPos(u8, wgsl, a10, "return") orelse return error.TestExpectedFind;
    try std.testing.expect(aret < a20);

    try nagaValidateOrSkip(wgsl, "fragment-early-return");
}

// When the early return targets an output that is ASSEMBLED at the trailing
// return from end-captured values (e.g. a frag_depth struct, whose depth is the
// LAST store), an early `return FragmentOutput(color, <last-depth>)` would use
// the wrong (later) depth. Rather than silently miscompile, glslpp must fail loud.
test "wgsl: early return into an assembled frag_depth output errors honestly" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 fragColor;
        \\layout(location=1) in float cond;
        \\void main() {
        \\    if (cond > 0.0) { fragColor = vec4(10.0); gl_FragDepth = 0.3; return; }
        \\    fragColor = vec4(20.0);
        \\    gl_FragDepth = 0.7;
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedEarlyReturn, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// A value-returning helper whose loop conditionally `return`s early used to be
// DELETED entirely by deadLoopElim (the early return wasn't counted as a side
// effect, and the result "escaped" only via that return), collapsing the helper
// to its post-loop fallthrough constant — a silent miscompile that validators
// accept. The loop must survive (OpLoopMerge present), and the `while`-loop
// counter must be lifted to OpPhi so backends don't hoist a stale header load.
test "wgsl: helper while-loop with early return is preserved and counter is live" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\layout(location=0) in float t;
        \\float search(float target) {
        \\    int i = 0;
        \\    float x = 0.0;
        \\    while (i < 20) {
        \\        x = x * x + 0.3;
        \\        if (x > target) return float(i) / 20.0;
        \\        i++;
        \\    }
        \\    return 1.0;
        \\}
        \\void main() { o = vec4(search(t)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    // #1: the loop survived deadLoopElim (OpLoopMerge = 246).
    try std.testing.expect(countSpirvOpcode(spirv, 246) >= 1);
    // #3: the `while` counter was converted to OpPhi (245), so there is no
    // header OpLoad of the counter for a backend to hoist into a stale snapshot.
    try std.testing.expect(countSpirvOpcode(spirv, 245) >= 1);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "helper-while-early-return");
}

// A `while` loop as the FIRST statement of a function makes the loop header the
// function's entry block; the back-edge then targets the entry block, which
// spirv-val rejects ("First block ... is targeted"). deadLoopElim used to mask
// this by deleting such loops. A pre-header block must be spliced in so the
// emitted SPIR-V is valid. Guard: the produced SPIR-V passes glslpp's own
// validator wrapper (spirv-val).
test "wgsl: loop-as-first-statement emits valid SPIR-V (entry not a branch target)" {
    // `drain`'s loop is the function's first statement and writes an SSBO (a real
    // side effect, so deadLoopElim keeps it). Without a spliced pre-header the
    // loop header would be the entry block and the back-edge would target it —
    // spirv-val rejects ("First block ... is targeted").
    const source =
        \\#version 450
        \\layout(local_size_x=1) in;
        \\layout(std430, binding=0) buffer B { int data[]; };
        \\void drain() { while (data[0] > 0) { data[0] = data[0] - 1; } }
        \\void main() { drain(); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .compute });
    defer alloc.free(spirv);
    try std.testing.expect(try glslpp.validateSPIRV(alloc, spirv));
}

// An ESCAPING condition variable (read after the loop) with a mid-body `break`
// cannot be safely lifted to a phi, so it stays a memory var whose value is
// LOADED at the loop header and reused in the body. The WGSL emitter used to
// HOIST that header load before `loop {`, so the body multiplied a stale
// pre-loop snapshot every iteration (`let s = x; loop { ... s*0.9 ... }`). The
// header load must be emitted INSIDE the loop so it re-reads each iteration.
test "wgsl: escaping condition-var while-loop re-reads inside the loop (no hoist)" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\layout(location=0) in float t;
        \\void main() {
        \\    float x = t;
        \\    int guard = 0;
        \\    while (x > 0.01) { x = x * 0.9; guard++; if (guard > 200) break; }
        \\    o = vec4(x);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    const loop_idx = std.mem.indexOf(u8, wgsl, "loop {") orelse return error.TestExpectedFind;
    // The `<v> * 0.9` decay must read a value (re)defined INSIDE the loop, not a
    // hoisted pre-loop snapshot: find the multiply, extract its left operand, and
    // assert that operand's `let` definition occurs after `loop {`.
    const mul = std.mem.indexOf(u8, wgsl, " * 0.9") orelse return error.TestExpectedFind;
    var s = mul;
    while (s > 0 and (std.ascii.isAlphanumeric(wgsl[s - 1]) or wgsl[s - 1] == '_')) s -= 1;
    const operand = wgsl[s..mul];
    const def_needle = try std.fmt.allocPrint(alloc, "let {s}:", .{operand});
    defer alloc.free(def_needle);
    const def_idx = std.mem.indexOf(u8, wgsl, def_needle) orelse return error.TestExpectedFind;
    try std.testing.expect(def_idx > loop_idx);
    try nagaValidateOrSkip(wgsl, "escaping-condvar-while");
}

// A `do { … } while(cond)` loop's latch ends in the bottom test (a conditional
// back-edge). Lifting its counter to a phi would place the increment on that
// conditional edge, which the structured emitters drop — leaving the counter
// never updated (infinite loop). loopCounterToPhi must NOT convert do-while
// counters; they stay correct memory vars. Guard: valid WGSL + the counter is
// assigned inside the loop.
test "wgsl: do-while counter is updated (not dropped by phi conversion)" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\layout(location=0) in float t;
        \\void main() {
        \\    float x = t;
        \\    int i = 0;
        \\    do { x = x * 0.5; i++; } while (x > 0.1 && i < 50);
        \\    o = vec4(x);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The counter increment `<v> + 1` must be stored back to a loop var. Find the
    // `+ 1` result and assert it is assigned to a name (`<name> = <result>;`),
    // i.e. the increment is not a dead let.
    try assertContains(wgsl, "+ 1");
    // Robust value-preservation check via naga (the miscompile is valid WGSL, so
    // this is a structural guard; semantics are confirmed against spirv-cross in
    // the conformance suite).
    try nagaValidateOrSkip(wgsl, "do-while-counter");
}

// An `in` function parameter mutated in place (the GLSL by-value copy) must be
// copied to a local at function ENTRY. Previously the copy was created lazily at
// the first write, so a use BEFORE it — a loop condition `while(lo<=hi)` — bound
// to the immutable parameter and the copy + increment were dead-code-eliminated,
// dropping `lo=lo+1` entirely (infinite loop). deadLoopElim used to mask this by
// deleting the whole loop; with live loops preserved it surfaced as a hang.
test "wgsl: mutated in-parameter is copied to a local at entry (increment preserved)" {
    const source =
        \\#version 450
        \\layout(location=0) out vec4 o;
        \\layout(location=0) in float t;
        \\int f(int lo, int hi) {
        \\    int acc = 0;
        \\    while (lo <= hi) { acc += lo; lo = lo + 1; }
        \\    return acc;
        \\}
        \\void main() { o = vec4(float(f(0, int(t)))); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expect(try glslpp.validateSPIRV(alloc, spirv));
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The mutated param must be promoted to a mutable local initialised from the
    // parameter. Extract the first param name from `fn f(<p>: i32, …)` and assert
    // a `var … : i32 = <p>;` copy exists (the increment then mutates that local,
    // not the dropped-on-the-floor original).
    const open = (std.mem.indexOf(u8, wgsl, "fn f(") orelse return error.TestExpectedFind) + "fn f(".len;
    const colon = std.mem.indexOfScalarPos(u8, wgsl, open, ':') orelse return error.TestExpectedFind;
    const param = std.mem.trim(u8, wgsl[open..colon], " ");
    const copy_needle = try std.fmt.allocPrint(alloc, ": i32 = {s};", .{param});
    defer alloc.free(copy_needle);
    try assertContains(wgsl, copy_needle);
    try nagaValidateOrSkip(wgsl, "mutable-in-param");
}

// The mutated-param promotion must be SCOPE-AWARE: a read-only `in` param that
// merely shares its name with a mutated inner-block local must NOT be promoted.
// Falsely promoting it copies the param into a local that DCE then eliminates,
// leaving a dangling SSA reference to the (now-undefined) parameter value —
// invalid SPIR-V. Guard: the read-only param compiles to valid SPIR-V.
test "wgsl: read-only param shadowed by a mutated inner local is not promoted" {
    const source =
        \\#version 450
        \\layout(location=0) in float u;
        \\layout(location=0) out vec4 o;
        \\float f(float p) {
        \\    float r = p;
        \\    { float p = u; p += 1.0; r += p; }
        \\    return r + p;
        \\}
        \\void main() { o = vec4(f(u)); }
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    try std.testing.expect(try glslpp.validateSPIRV(alloc, spirv));
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "shadowed-readonly-param");
}

// #170 (H) review fix C1: a nested-struct INPUT block emitted as a plain WGSL
// struct (`struct VertexIn { a: Foo }`) must also DECLARE the inner struct
// (`Foo`); otherwise naga rejects ("no definition in scope for `Foo`"). The
// corpus fixture masked this (a sibling plain input forced `Foo` to be emitted
// as a side effect) — this MINIMAL single-block shader is the real guard.
test "wgsl: nested-struct input block emits its inner struct decl" {
    const src: [:0]const u8 =
        \\#version 450
        \\struct Foo { vec4 a; vec4 b; };
        \\in VertexIn { Foo a; Foo b; } vin;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vin.a.a + vin.b.b; }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "struct Foo {");
    try nagaValidateOrSkip(wgsl, "nested-struct input inner decl");
}

// #170 (H) review fix I2: an INPUT interface block with an ARRAY member
// (`in Blk { float a[4]; }`) emitted `@location(0) a: array<f32,4>` — naga
// forbids an array at a @location. Symmetric to the array OUTPUT case: flatten
// into per-element leaf @location params and reassemble the array in the local.
test "wgsl: input interface-block array member is flattened to per-element @location" {
    const src: [:0]const u8 =
        \\#version 450
        \\in Blk { float a[4]; } b;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(b.a[0] + b.a[3]); }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "@location(0) b_a_0: f32");
    try assertContains(wgsl, "@location(3) b_a_3: f32");
    try assertNotContains(wgsl, "@location(0) a: array");
    try nagaValidateOrSkip(wgsl, "input array-member flattening");
}

// #170 (H) review fix I2: a matrix member in an INPUT block has no per-element
// @location flattening here (would need column reassembly) — fail loud rather
// than emit a naga-invalid `@location(0) m: mat4x4f`.
test "wgsl: input interface-block matrix member is an honest error" {
    const src: [:0]const u8 =
        \\#version 450
        \\in Blk { mat4 m; } b;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = b.m[0]; }
    ;
    try std.testing.expectError(error.UnsupportedOp, compileToWgsl(src));
}

// #170 (I): a spec-constant-sized array is unrepresentable in WGSL except as a
// workgroup-var type (override array sizing is workgroup-only). A function-local
// (or struct-member / storage) spec-const-sized array must fail loud rather than
// emit a runtime `array<T>` (naga-invalid as a local) or drop members to an empty
// struct.
test "wgsl: spec-constant-sized function-local array is an honest error" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(constant_id = 0) const int a = 1;
        \\layout(constant_id = 1) const int b = 2;
        \\layout(set = 0, binding = 0) buffer B { int data[]; };
        \\void main() {
        \\    int local_arr[b];
        \\    local_arr[a] = a;
        \\    data[0] = local_arr[1 - a];
        \\}
    ;
    try std.testing.expectError(error.UnsupportedOp, compileCompToWgsl(src));
}

// #170 (derivatives): the FINE-quality derivative variants — dFdxFine /
// dFdyFine / fwidthFine — lower to OpDPdxFine (210) / OpDPdyFine (211) /
// OpFwidthFine (212). The WGSL backend already mapped the plain (dpdx/dpdy/
// fwidth) and Coarse (dpdxCoarse/…) variants, but the Fine arms were missing,
// so these honest-errored even though WGSL HAS dpdxFine/dpdyFine/fwidthFine
// builtins (a missing-but-representable gap, not a true unrepresentable op).
// Oracle: naga validates dpdxFine/dpdyFine/fwidthFine on a vec2<f32>.
test "wgsl: fine-quality derivatives map to dpdxFine/dpdyFine/fwidthFine" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec2 a = dFdxFine(uv);
        \\    vec2 b = dFdyFine(uv);
        \\    vec2 c = fwidthFine(uv);
        \\    o = vec4(a + b + c, 0.0, 0.0);
        \\}
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "dpdxFine(");
    try assertContains(wgsl, "dpdyFine(");
    try assertContains(wgsl, "fwidthFine(");
}

// #294: a runtime-sized SSBO array `.length()` (`buffer B { float d[]; }; … d.length()`)
// must lower to OpArrayLength → WGSL `arrayLength(&buf.member)` (returning u32), NOT be
// constant-folded to 0 (the prior frontend silent-wrong). Oracle: naga validates the
// emitted `arrayLength(&B_data.d)`. OpArrayLength (opcode 68) is modeled in
// compact_ids.zig (`68 => rt(2, "il")`) so the optimizer's id-compaction preserves the
// struct-ptr id and passes the member-index literal through unmodified.
test "wgsl: runtime SSBO array .length() -> arrayLength(&buf.member)" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { float d[]; };
        \\layout(std430, binding = 1) buffer Out { uint n; };
        \\void main() { n = uint(d.length()); }
    ;
    const wgsl = try compileCompToWgsl(src);
    defer alloc.free(wgsl);
    // Assert the resolved buffer name + member (not the "buf"/"arr" fallbacks).
    try assertContains(wgsl, "arrayLength(&B");
    try assertContains(wgsl, ".d)");
    try assertNotContains(wgsl, "unhandled");
    try assertNotContains(wgsl, ".arr)");
    try nagaValidateOrSkip(wgsl, "ssbo_array_length");
}

// #294/#296: the NAMED-INSTANCE block form (`buffer B { float d[]; } b; → b.d.length()`)
// — a `.member_access` node, not a bare identifier — must also lower to OpArrayLength →
// `arrayLength(&b.d)`, not fold to 0. The frontend resolves the instance var `b` (the
// struct pointer) + the member `d`'s index. Oracle: naga validates `arrayLength(&b.d)`.
test "wgsl: named-instance SSBO array b.d.length() -> arrayLength(&b.d)" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { float d[]; } b;
        \\layout(std430, binding = 1) buffer Out { uint n; };
        \\void main() { n = uint(b.d.length()); }
    ;
    const wgsl = try compileCompToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "arrayLength(&");
    try assertContains(wgsl, ".d)");
    try assertNotContains(wgsl, "unhandled");
    try nagaValidateOrSkip(wgsl, "ssbo_named_instance_length");
}

// #170: VECTOR isnan/isinf (OpIsNan/OpIsInf with a bvecN result) previously honest-errored
// — only the scalar forms were lowered. WGSL comparison operators are componentwise on
// vectors (returning vecN<bool>), and `&` is componentwise logical-AND on bool vectors, so
// both have a faithful, naga-valid lowering: isnan(v) -> (v != v); isinf(v) -> (v != vecN(0.0))
// & (v * 2.0 == v). No `isnan`/`isinf`/`isNan`/`isInf` identifier may leak (naga rejects).
// Each is exercised in its OWN shader: a combined isnan+isinf shader currently has its
// OpIsInf value-numbered into the OpIsNan result by the SPIR-V optimizer (a pre-existing,
// orthogonal silent-wrong), which would erase the isinf path before the backend sees it.
test "wgsl: VECTOR isnan lowers to (v != v) (#170)" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(location = 0) in vec3 v;
        \\void main() { bvec3 n = isnan(v); o = vec4(float(any(n)), 0.0, 0.0, 1.0); }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "vec3<bool> = (v != v)");
    try assertNotContains(wgsl, "isnan");
    try assertNotContains(wgsl, "isNan");
    try assertNotContains(wgsl, "unhandled");
    try nagaValidateOrSkip(wgsl, "vector_isnan");
}

test "wgsl: VECTOR isinf lowers to the componentwise (v != vecN(0.0)) & (v*2 == v) idiom (#170)" {
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(location = 0) in vec3 v;
        \\void main() { bvec3 i = isinf(v); o = vec4(float(any(i)), 0.0, 0.0, 1.0); }
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "!= vec3f(0.0)) & ("); // componentwise &, float-typed zero
    try assertContains(wgsl, "* 2.0 == ");
    try assertNotContains(wgsl, "isinf");
    try assertNotContains(wgsl, "isInf");
    try assertNotContains(wgsl, "unhandled");
    try nagaValidateOrSkip(wgsl, "vector_isinf");
}

// #170: isnan/isinf used in a LOOP CONDITION are deferred into the loop-header REPLAY range
// (emitSimpleInstruction), a distinct emit path from the straight-line body. Without arms
// there too, `while (!isnan(x))` honest-errors despite the main-path lowering. This guards
// the replay path emits the same naga-valid idiom.
test "wgsl: isnan in a loop condition lowers via the replay path (#170)" {
    // The loop CONDITION is solely `isnan(x)` so the only op deferred into the loop-header
    // replay range is OpIsNan (a richer condition would also need LogicalAnd/comparison
    // replay arms, which are pre-existing gaps unrelated to this fix). The `(x != x)` idiom
    // must appear inside the emitted `loop {` and be naga-valid.
    const src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in float a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float x = a;
        \\    while (isnan(x)) { x = 0.0; }
        \\    o = vec4(x, 0.0, 0.0, 1.0);
        \\}
    ;
    const wgsl = try compileToWgsl(src);
    defer alloc.free(wgsl);
    try assertContains(wgsl, "loop {");
    try assertContains(wgsl, "!= "); // the (x != x) idiom, emitted in the replay path
    try assertNotContains(wgsl, "isnan");
    try assertNotContains(wgsl, "isNan");
    try assertNotContains(wgsl, "unhandled");
    try nagaValidateOrSkip(wgsl, "isnan_loop_condition");
}

// Rewrite the opcode of the FIRST instruction whose opcode == `from` to `to`,
// preserving the word count. Used to inject an opcode glslang does not itself
// emit by reusing an instruction with an identical operand layout. Returns
// error if no such instruction is found (keeps the test honest).
fn patchFirstOpcode(words: []u32, from: u16, to: u16) !void {
    var pos: usize = 5; // skip the 5-word header
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        if (wc == 0) return error.MalformedSpirv;
        if (@as(u16, @truncate(words[pos] & 0xFFFF)) == from) {
            words[pos] = (wc << 16) | to;
            return;
        }
        pos += wc;
    }
    return error.OpcodeNotFound;
}

// #170: OpQuantizeToF16 (116) — quantize a 32-bit float to the precision/range
// expressible by a 16-bit float, then widen back to 32 bits. WGSL has an EXACT
// 1:1 builtin, `quantizeToF16`, with identical semantics (componentwise on
// vectors). The opcode was absent from glslpp's `Op` enum entirely, so it
// honest-errored (UnsupportedOp) instead of lowering. glslang never emits
// OpQuantizeToF16 from GLSL (there is no GLSL builtin), so — like the other
// external-SPIR-V #170 fixes — we synthesize it by reusing an OpFNegate
// instruction (identical {result-type, result-id, operand} layout) and
// patching its opcode. The point of the fix is the spirvToWGSL public API used
// on optimizer-/tool-produced or hand-written SPIR-V.
test "wgsl: scalar OpQuantizeToF16 lowers to quantizeToF16 (naga-valid) (#170)" {
    const spirv = try compileToSpirv("quantize_scalar",
        \\#version 450
        \\layout(location = 0) in float a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float q = -a; // OpFNegate, patched to OpQuantizeToF16
        \\    o = vec4(q, 0.0, 0.0, 1.0);
        \\}
    );
    defer alloc.free(spirv);
    try patchFirstOpcode(spirv, 127, 116); // OpFNegate(127) -> OpQuantizeToF16(116)
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "quantizeToF16(");
    try assertNotContains(wgsl, "unhandled");
    try nagaValidateOrSkip(wgsl, "quantize-scalar");
}

test "wgsl: vector OpQuantizeToF16 lowers componentwise to quantizeToF16 (naga-valid) (#170)" {
    const spirv = try compileToSpirv("quantize_vec",
        \\#version 450
        \\layout(location = 0) in vec3 a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec3 q = -a; // OpFNegate (vec3), patched to OpQuantizeToF16
        \\    o = vec4(q, 1.0);
        \\}
    );
    defer alloc.free(spirv);
    try patchFirstOpcode(spirv, 127, 116); // OpFNegate(127) -> OpQuantizeToF16(116)
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "quantizeToF16(");
    try assertNotContains(wgsl, "unhandled");
    try nagaValidateOrSkip(wgsl, "quantize-vec");
}

// #170: OpFUnordNotEqual (183) — the "unordered" float `!=`. glslang emits it for
// every GLSL float `!=` / `notEqual()` (the ordered FOrdNotEqual is NOT what GLSL
// `!=` lowers to). The WGSL backend mapped only the ordered FOrd* compare family,
// so OpFUnordNotEqual fell through to the honest-error catch-all even though it has
// an EXACT WGSL equivalent: WGSL comparison operators follow IEEE-754, so WGSL `!=`
// is itself the *unordered* not-equal (true when either operand is NaN) —
// componentwise on vecN<f32>. The faithful lowering is therefore the plain `!=`
// operator (NOT a NaN guard); the other 5 FUnord* ops have no single-operator WGSL
// match (WGSL's ==,<,>,<=,>= are all ordered) and correctly stay honest-errors.
test "wgsl: scalar OpFUnordNotEqual (float !=) lowers to != (naga-valid) (#170)" {
    const spirv = try compileToSpirv("funord_ne_scalar",
        \\#version 450
        \\layout(location = 0) in float a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    bool ne = (a != 0.0); // OpFUnordNotEqual
        \\    o = vec4(ne ? 1.0 : 0.0, 0.0, 0.0, 1.0);
        \\}
    );
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "!=");
    try assertNotContains(wgsl, "unhandled");
    try nagaValidateOrSkip(wgsl, "funord-ne-scalar");
}

test "wgsl: vector OpFUnordNotEqual (notEqual) lowers componentwise to != (naga-valid) (#170)" {
    const spirv = try compileToSpirv("funord_ne_vec",
        \\#version 450
        \\layout(location = 0) in vec3 a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    bvec3 n = notEqual(a, vec3(0.0)); // OpFUnordNotEqual (vector)
        \\    o = vec4(float(n.x), float(n.y), float(n.z), 1.0);
        \\}
    );
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "!=");
    try assertNotContains(wgsl, "unhandled");
    try nagaValidateOrSkip(wgsl, "funord-ne-vec");
}

// #170: a conditional `break` inside a loop body — `for(...){ if(cond) break; ... }` —
// was SILENT-WRONG. glslang `-V` (unoptimized) emits the break as an INDIRECT
// trampoline: `OpSelectionMerge %m; OpBranchConditional %cond %brk %m` where %brk is
// a SEPARATE block whose only instruction is `OpBranch <loop_merge>`. The WGSL
// structurizer's break-detection matched only the DIRECT form (the BranchConditional
// target IS the loop merge), so the trampoline branch was dropped → `if (cond) { }`
// EMPTY body → the loop never exits early (ran all 10 iterations instead of stopping
// at i==5). The fix recognizes a pure break-trampoline target and emits
// `if (cond) { break; }`, mirroring the direct-break path.
test "wgsl: conditional break in loop body emits break, not an empty if (#170)" {
    const spirv = compileToSpirv("cond_break_body",
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        if (i == 5) break;
        \\        sum += x * float(i);
        \\    }
        \\    o = vec4(sum);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Two breaks expected: the loop-condition exit `if (!(i < 10)) { break; }` AND the
    // body conditional `if (i == 5) { break; }`. Before the fix only the former existed
    // (the body break was dropped → empty `if (cond) { }` = silent-wrong infinite-ish).
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, wgsl, pos, "break")) |idx| : (pos = idx + 5) n += 1;
    if (n < 2) {
        std.debug.print("expected >=2 'break' in WGSL (loop-exit + body break), got {d}:\n{s}\n", .{ n, wgsl });
        return error.TestExpectedFind;
    }
    try nagaValidateOrSkip(wgsl, "cond-break-body");
}

// #170: the CONTINUE sibling of the break fix above. glslang `-V` (unoptimized)
// emits `if (cond) continue;` as an INDIRECT trampoline: `OpSelectionMerge %m;
// OpBranchConditional %cond %cont %m` where `%cont` is a SEPARATE block whose only
// instruction is `OpBranch <loop_continue>`. The structurizer only detected the
// DIRECT continue form (branch target IS the loop-continue block), so the trampoline
// fell through to the general selection handler → an empty `if (cond) { }` and the
// trampoline's `OpBranch <loop_continue>` was skipped → the `continue` was DROPPED
// = silent-wrong (the rest of the body runs when it should have been skipped). The
// fix must also route through the phi-update machinery so the loop counter still
// advances on the early-continue path.
test "wgsl: conditional continue in loop body emits continue, not an empty if (#170)" {
    const spirv = compileToSpirv("cond_continue_body",
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        if (i == 3) continue;
        \\        sum += x * float(i);
        \\    }
        \\    o = vec4(sum);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Before the fix the body `if (i == 3) continue;` was dropped → empty `if (cond) { }`
    // with NO `continue;` emitted anywhere, so the presence of `continue;` is itself the
    // discriminator (the loop-exit `if (!cond) { break; }` never emits `continue;`).
    try assertContains(wgsl, "continue;");
    try nagaValidateOrSkip(wgsl, "cond-continue-body");
}

// #170: the negated-condition counterpart of the continue test above — exercises the
// `false_is_continue` branch (glslang may emit `OpBranchConditional %cond %merge
// %cont`, i.e. the CONTINUE is on the FALSE edge). Without the trampoline fix this
// path also dropped the continue.
test "wgsl: negated conditional continue in loop body emits continue (#170)" {
    const spirv = compileToSpirv("cond_continue_neg",
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        if (i < 3) { sum += x; } else { continue; }
        \\        sum += x * float(i);
        \\    }
        \\    o = vec4(sum);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "continue;");
    try nagaValidateOrSkip(wgsl, "cond-continue-neg");
}

// #170: OpImageSampleExplicitLod with a `Grad` image operand (GLSL textureGrad —
// explicit ddx/ddy gradients) was lowered to `textureSampleLevel(t, s, coord, ddx)`
// — the handler ignored the image-operands mask and misread the GRADIENT vec2 as a
// scalar LOD. That is both semantically wrong AND naga-invalid ("Sample level (exact)
// type is invalid", a vec2 where a scalar f32 is required). WGSL spells explicit-
// gradient sampling `textureSampleGrad(t, s, coord, ddx, ddy)`.
test "wgsl: textureGrad (OpImageSampleExplicitLod Grad) -> textureSampleGrad (#170)" {
    const spirv = compileToSpirv("tex_grad",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureGrad(s, uv, vec2(0.1), vec2(0.2)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSampleGrad(");
    try assertNotContains(wgsl, "textureSampleLevel");
    try nagaValidateOrSkip(wgsl, "tex-grad");
}

// #170: GLSL `texture(s, uv, bias)` (an LOD-bias sample) was SILENTLY DROPPING the
// bias — glslpp's frontend emitted OpImageSampleImplicitLod WITHOUT the Bias image
// operand, so the WGSL was a plain `textureSample(s, sampler, uv)` that samples the
// wrong mip level. The frontend now emits the Bias operand and the WGSL back-end
// spells it `textureSampleBias(t, s, coord, bias)` (fragment-only) — exercised here
// through the FULL glslpp pipeline (frontend→WGSL), with the bias value (1.5) surviving.
test "wgsl: texture(s, uv, bias) (OpImageSampleImplicitLod Bias) -> textureSampleBias (#170)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = texture(s, uv, 1.5); }
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSampleBias(");
    try assertContains(wgsl, "1.5");
    try nagaValidateOrSkip(wgsl, "tex-bias");
}

// #170: OpImageSampleImplicitLod with BOTH Bias (0x1) and ConstOffset (0x8) — GLSL
// textureOffset(s, uv, offset, bias). The constant offset must reach the
// textureSampleBias call as a trailing argument; dropping it is silent-wrong (the
// neighborhood is shifted). Guards the happy path of the Bias-arm offset suffix.
// (Routes through glslang/compileToSpirv — the external-SPIR-V backend arm —
// independent of the frontend Bias+ConstOffset test below.)
test "wgsl: textureOffset(s, uv, offset, bias) keeps the const offset, backend arm (#170)" {
    const spirv = compileToSpirv("tex_bias_offset",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureOffset(s, uv, ivec2(1, 2), 1.5); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSampleBias(");
    try assertContains(wgsl, "vec2<i32>(1, 2)");
    try nagaValidateOrSkip(wgsl, "tex-bias-offset");
}

// #170 (defensive): a Bias instruction whose mask CLAIMS a ConstOffset (0x8) but
// whose offset <id> operand word is truncated away must FAIL LOUDLY, not silently
// emit a textureSampleBias with the claimed offset dropped. No conformant producer
// emits this, so we synthesize it by truncating the trailing offset word of a real
// textureOffset(...,bias) instruction (OpImageSampleImplicitLod = 87). Mirrors the
// explicit honest-error guards on the sibling non-Bias / textureSampleLevel arms.
test "wgsl: Bias with a truncated ConstOffset operand is an honest error (#170)" {
    const spirv = compileToSpirv("tex_bias_trunc",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureOffset(s, uv, ivec2(1, 2), 1.5); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const truncated = truncateLastOperand(spirv, 87) catch return error.SkipZigTest;
    defer alloc.free(truncated);
    try std.testing.expectError(
        error.UnsupportedImageOperands,
        glslpp.spirvToWGSL(alloc, truncated, .{}),
    );
}

// #170: OpImageSampleExplicitLod with BOTH Grad (0x4) and ConstOffset (0x8) — GLSL
// textureGradOffset(s, uv, ddx, ddy, offset). The constant offset must reach the
// textureSampleGrad call as a trailing argument (after ddx, ddy); dropping it is
// silent-wrong. Guards the happy path of the Grad-arm offset suffix. (glslpp's own
// frontend rejects textureGradOffset — see the honest-error test below — so this
// drives the external-SPIR-V backend arm via glslang.)
test "wgsl: textureGradOffset keeps the const offset, backend arm (#170)" {
    const spirv = compileToSpirv("tex_grad_offset",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureGradOffset(s, uv, vec2(0.1), vec2(0.2), ivec2(2, 3)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSampleGrad(");
    try assertContains(wgsl, "vec2<i32>(2, 3)");
    try nagaValidateOrSkip(wgsl, "tex-grad-offset");
}

// #170 (defensive): a Grad instruction whose mask CLAIMS a ConstOffset (0x8) but
// whose offset <id> operand word is truncated away must FAIL LOUDLY, not silently
// emit a textureSampleGrad with the claimed offset dropped. Synthesized by
// truncating the trailing offset word of a real textureGradOffset instruction
// (OpImageSampleExplicitLod = 88).
test "wgsl: Grad with a truncated ConstOffset operand is an honest error (#170)" {
    const spirv = compileToSpirv("tex_grad_trunc",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureGradOffset(s, uv, vec2(0.1), vec2(0.2), ivec2(2, 3)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const truncated = truncateLastOperand(spirv, 88) catch return error.SkipZigTest;
    defer alloc.free(truncated);
    try std.testing.expectError(
        error.UnsupportedImageOperands,
        glslpp.spirvToWGSL(alloc, truncated, .{}),
    );
}

// #170: OpImageSampleImplicitLod with a `ConstOffset` image operand (GLSL
// textureOffset(s, uv, offset) — a const-offset sample, no bias) was lowered to a
// plain `textureSample(s, sampler, uv)`, SILENTLY DROPPING the offset = silent-wrong.
// WGSL's textureSample accepts a trailing const-offset arg —
// `textureSample(t, s, coord, offset)` — so the (1,0) offset must survive into the
// output. glslang encodes this as ConstOffset (0x8) with NO Bias bit, so it exercises
// the non-Bias arm of the handler (the Bias arm at ~6511 already handles its own
// offset). This routes through glslang (compileToSpirv) to exercise the
// parsed-SPIR-V → WGSL backend arm with an independent oracle; glslpp's OWN
// frontend lowering of textureOffset is covered by a separate test below.
test "wgsl: textureOffset(s, uv, offset) (OpImageSampleImplicitLod ConstOffset) keeps the offset (#170)" {
    const spirv = compileToSpirv("tex_offset",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureOffset(s, uv, ivec2(1, 0)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The offset must reach the textureSample call as a trailing 4th argument; the
    // bare (dropped-offset) form ends `..., uv)`. The `, vec2<i32>(1, 0))` substring
    // only occurs as a trailing call arg, proving the (1,0) offset survived.
    try assertContains(wgsl, "textureSample(");
    try assertContains(wgsl, ", vec2<i32>(1, 0))");
    try nagaValidateOrSkip(wgsl, "tex-offset");
}

// #170: the same ConstOffset drop on the EXPLICIT-LOD path. GLSL
// textureLodOffset(s, uv, lod, offset) compiles to OpImageSampleExplicitLod with
// Lod (0x2) | ConstOffset (0x8); the non-Grad arm read only the LOD operand and
// dropped the offset = silent-wrong. WGSL spells it
// `textureSampleLevel(t, s, coord, lod, offset)` — the offset is the trailing arg.
test "wgsl: textureLodOffset (OpImageSampleExplicitLod Lod|ConstOffset) keeps the offset (#170)" {
    const spirv = compileToSpirv("tex_lod_offset",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureLodOffset(s, uv, 0.0, ivec2(1, 0)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSampleLevel(");
    try assertContains(wgsl, ", vec2<i32>(1, 0))");
    try nagaValidateOrSkip(wgsl, "tex-lod-offset");
}

// #170: the ARRAYED ConstOffset branch — textureOffset on a sampler2DArray. WGSL
// takes the const-offset as the LAST arg, AFTER the separate rounded i32 layer:
// textureSample(t, s, coord.xy, i32(round(coord.z)), offset). Emitting the offset
// before the layer (or dropping it) is silent-wrong — only naga catches the
// ordering. Guards the arrayed emit branch of the fix (the non-arrayed tests above
// exercise only the scalar-coord branch).
test "wgsl: textureOffset on sampler2DArray keeps the offset after the layer (#170)" {
    const spirv = compileToSpirv("tex_offset_arr",
        \\#version 450
        \\layout(binding = 0) uniform sampler2DArray s;
        \\layout(location = 0) in vec3 uvw;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureOffset(s, uvw, ivec2(1, 0)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The rounded layer index precedes the trailing offset.
    try assertContains(wgsl, "textureSample(");
    try assertContains(wgsl, ")), vec2<i32>(1, 0))");
    try nagaValidateOrSkip(wgsl, "tex-offset-array");
}

// #170: the FRONTEND analog of the two tests above. The two preceding tests
// route through glslang (compileToSpirv); this one drives glslpp's OWN frontend
// (compileToWgsl = compileToSPIRV + spirvToWGSL). glslpp's analyzer ACCEPTS
// textureOffset and lowers it to `.image_sample` with [sampler, coord, offset],
// but codegen's `.image_sample` arm emitted OpImageSampleImplicitLod WITHOUT the
// ConstOffset image operand — silently dropping operand[2]. The native path
// therefore produced `textureSample(s, s_sampler, uv)` (offset gone) = silent-
// wrong, sampling the WRONG texels. The offset must survive as a trailing
// const-offset arg. (Contrast the sibling tests' comment claiming the frontend
// "rejects textureOffset" — it does not; it drops the offset.)
test "wgsl: textureOffset via glslpp frontend keeps the ConstOffset (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureOffset(s, uv, ivec2(1, 0)); }
    );
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSample(");
    try assertContains(wgsl, ", vec2<i32>(1, 0))");
    try nagaValidateOrSkip(wgsl, "tex-offset-frontend");
}

// #170: the 4-arg fragment overload textureOffset(s, P, offset, bias) carries
// BOTH a constant offset (→ ConstOffset) and an LOD bias (→ Bias). The new
// image_sample_offset codegen arm must emit Bias|ConstOffset, not just
// ConstOffset — dropping the bias samples the wrong mip (silent-wrong). WGSL
// spells this textureSampleBias(t, s, coord, bias, offset).
test "wgsl: textureOffset(s, uv, offset, bias) keeps BOTH bias and offset (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = textureOffset(s, uv, ivec2(1, 0), 0.5); }
    );
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureSampleBias(");
    try assertContains(wgsl, "0.5");
    try assertContains(wgsl, ", vec2<i32>(1, 0))");
    try nagaValidateOrSkip(wgsl, "tex-offset-bias-frontend");
}

// #170: textureLodOffset with a NON-CONSTANT offset cannot become a SPIR-V
// ConstOffset (which requires an OpConstantComposite); without a gate codegen
// would emit ConstOffset pointing at a runtime value = invalid SPIR-V. Must
// honest-error, mirroring the textureOffset gate.
test "wgsl: textureLodOffset with a non-constant offset honest-errors (#170)" {
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRV(alloc,
            \\#version 450
            \\layout(binding = 0) uniform sampler2D s;
            \\layout(location = 0) in vec2 uv;
            \\layout(location = 1) flat in ivec2 dyn;
            \\layout(location = 0) out vec4 o;
            \\void main() { o = textureLodOffset(s, uv, 0.0, dyn); }
        , .{ .stage = .fragment }),
    );
}

// #170: textureGradOffset is deliberately NOT lowered by glslpp's frontend (it
// is absent from isTextureBuiltin, so it honest-errors via "builtin-not-
// lowerable"). It IS representable in WGSL — textureSampleGrad(t, s, coord, ddx,
// ddy, offset) — but the frontend emits ONE shared SPIR-V to all back-ends, and
// the HLSL/MSL sample emitters silently DROP the ConstOffset (HLSL .SampleGrad
// omits the offset arg). Lowering it here would convert today's honest-error into
// a NEW silent-wrong on those back-ends. Honest-error is the #170-compliant
// choice until every back-end carries the offset. (Contrast textureOffset, whose
// offset was already dropped pre-fix on HLSL/MSL — no regression there.)
test "wgsl: textureGradOffset honest-errors via the frontend (not silent-wrong) (#170)" {
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRV(alloc,
            \\#version 450
            \\layout(binding = 0) uniform sampler2D s;
            \\layout(location = 0) in vec2 uv;
            \\layout(location = 0) out vec4 o;
            \\void main() { o = textureGradOffset(s, uv, vec2(0.1), vec2(0.2), ivec2(1, 0)); }
        , .{ .stage = .fragment }),
    );
}

// #170: textureProjOffset has NO faithful WGSL lowering — WGSL has no projective
// sampler builtin, and the manual perspective-divide path used for textureProj
// cannot carry a ConstOffset. It is deliberately kept OUT of isTextureBuiltin so
// it honest-errors (an unrecognized builtin) rather than emitting a wrong sample.
// (Compile through the native frontend; expect an error.) This is the
// #170-compliant counterpart to the textureOffset fix: faithful where
// representable on the target back-end, loud where not — never silent-wrong.
test "wgsl: textureProjOffset honest-errors (no faithful lowering) (#170)" {
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRV(alloc,
            \\#version 450
            \\layout(binding = 0) uniform sampler2D s;
            \\layout(location = 0) in vec4 P;
            \\layout(location = 0) out vec4 o;
            \\void main() { o = textureProjOffset(s, P, ivec2(1, 0)); }
        , .{ .stage = .fragment }),
    );
}

// #170: textureOffset with a NON-CONSTANT offset cannot become a SPIR-V
// ConstOffset (which requires an OpConstantComposite). glslpp must honest-error
// rather than emit invalid SPIR-V / a silently-wrong sample.
test "wgsl: textureOffset with a non-constant offset honest-errors (#170)" {
    try std.testing.expectError(
        error.SemanticFailed,
        glslpp.compileToSPIRV(alloc,
            \\#version 450
            \\layout(binding = 0) uniform sampler2D s;
            \\layout(location = 0) in vec2 uv;
            \\layout(location = 1) flat in ivec2 dyn;
            \\layout(location = 0) out vec4 o;
            \\void main() { o = textureOffset(s, uv, dyn); }
        , .{ .stage = .fragment }),
    );
}

// #170: WGSL forbids the filtering textureSample/textureSampleLevel builtins on
// INTEGER textures (texture_2d<i32>/<u32> are non-filterable) — only textureLoad is
// allowed. GLSL `texture(isampler2D, uv)` (a normalized-coordinate sample of an
// integer texture) therefore has no faithful WGSL form. glslpp emitted
// `textureSample(s, s_sampler, uv)` on a `texture_2d<i32>` — naga rejects it ("Entry
// point invalid") = silent-wrong. It must honest-error instead. (texelFetch on the
// same isampler2D is unaffected — it lowers to textureLoad, which integer textures
// DO support.)
test "wgsl: texture() on an integer sampler honest-errors, not naga-invalid textureSample (#170)" {
    const spirv = compileToSpirv("isampler_sample",
        \\#version 450
        \\layout(binding = 0) uniform isampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(texture(s, uv)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedIntegerTextureSample, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// The texelFetch counterpart MUST still compile: textureLoad is valid on integer
// textures, so the honest-error above must be narrow (sample ops only). (#170)
test "wgsl: texelFetch on an integer sampler still lowers to textureLoad (#170)" {
    const spirv = compileToSpirv("isampler_fetch",
        \\#version 450
        \\layout(binding = 0) uniform isampler2D s;
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(texelFetch(s, ivec2(uv), 0)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureLoad(");
    try nagaValidateOrSkip(wgsl, "isampler-fetch");
}

// Projective sampling of an integer texture is the same non-filterable case as the
// plain sample arms — must honest-error, not emit a naga-invalid textureSample. (#170)
test "wgsl: textureProj on an integer sampler honest-errors (#170)" {
    const spirv = compileToSpirv("isampler_proj",
        \\#version 450
        \\layout(binding = 0) uniform isampler2D s;
        \\layout(location = 0) in vec3 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(textureProj(s, uv)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedIntegerTextureSample, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: the STRUCT form of GLSL frexp/modf — `frexp(x, e)` with a separate out-param,
// which glslang lowers to OpExtInst FrexpStruct (52) returning a `{fract, exp}` struct
// consumed by OpCompositeExtract — was emitted as `let v: ResType = frexp(x)` using
// glslang's struct type name `ResType` (UNDEFINED in WGSL) plus generic `._0`/`._1`
// member access. WGSL `frexp(x)` returns an un-nameable builtin struct with `.fract`
// and `.exp` fields, so the result must be emitted WITHOUT a type annotation and the
// extracts mapped to the named fields. (The POINTER forms Frexp=51/Modf=35 were
// already handled.)
test "wgsl: frexp struct-form lowers to .fract/.exp, not ResType._0/._1 (#170)" {
    const spirv = compileToSpirv("frexp_struct",
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() { int e; float m = frexp(x, e); float r = ldexp(m, e); o = vec4(r, float(e), 0.0, 1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "frexp(");
    try assertContains(wgsl, ".fract");
    try assertNotContains(wgsl, "ResType");
    try assertNotContains(wgsl, "._0");
    try nagaValidateOrSkip(wgsl, "frexp-struct");
}

// modf struct-form (ModfStruct=36): members are {fract, whole}. (#170)
test "wgsl: modf struct-form lowers to .fract/.whole, not ResType._0/._1 (#170)" {
    const spirv = compileToSpirv("modf_struct",
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() { float ip; float fp = modf(x, ip); o = vec4(fp, ip, 0.0, 1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "modf(");
    try assertNotContains(wgsl, "ResType");
    try assertNotContains(wgsl, "._0");
    try nagaValidateOrSkip(wgsl, "modf-struct");
}

// #170: an ANONYMOUS SSBO block (`buffer B { float d[]; };` with no instance name)
// emitted an EMPTY WGSL variable name — `var<storage, read_write> : B;` (a naga syntax
// error, "expected identifier") and member accesses with no base (`.d[0]`). glslang
// names the block TYPE ("B") but emits an empty OpName for the variable instance, so
// the `orelse "buffer"` fallback never fired (the name is "" not null). A name is now
// synthesized from the block type and registered in the names map so BOTH the
// declaration and the access chains use it. (Named SSBOs were already fine.)
test "wgsl: anonymous SSBO block gets a synthesized var name (naga-valid) (#170)" {
    const spirv = compileToSpirv("anon_ssbo",
        \\#version 450
        \\layout(std430, binding = 0) buffer B { float d[]; };
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(d[0] + x); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The storage variable must have a name (NOT `var<storage, read_write> : B;`) and
    // the member access must carry the base (NOT a bare `.d[`).
    try assertNotContains(wgsl, "read_write> :");
    try nagaValidateOrSkip(wgsl, "anon-ssbo");
}

// #170: an UNBOUNDED descriptor sampler array (`uniform sampler2D tex[];`,
// GL_EXT_nonuniform_qualifier) slipped past the sampler-array honest-error guard —
// which only matched a fixed-size `OpTypeArray`, not the unbounded
// `OpTypeRuntimeArray`. The backend then DROPPED the (undeclarable) array variable
// and emitted `textureSample(tex[i], tex[i]_sampler, uv)` — an undeclared `tex[i]`
// plus a malformed `tex[i]_sampler` (naga reject) = silent-wrong. WGSL core has no
// sampler/texture arrays (binding_array is non-core), so it must honest-error like
// the bounded `tex[4]` form already does.
test "wgsl: unbounded descriptor sampler array honest-errors (#170)" {
    const spirv = compileToSpirv("unbounded_sampler_array",
        \\#version 450
        \\#extension GL_EXT_nonuniform_qualifier : require
        \\layout(binding = 0) uniform sampler2D tex[];
        \\layout(location = 0) flat in int i;
        \\layout(location = 1) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = texture(tex[nonuniformEXT(i)], uv); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedSamplerArray, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: WGSL has no 64-bit float (f64 / GLSL `double`) — not even a core extension.
// glslpp's type mapping collapsed every OpTypeFloat to f32 AND misread f64 CONSTANTS
// (the 64-bit IEEE-754 bit pattern reinterpreted as f32 = garbage — e.g. `1.0e15lf`
// emitted as ~6.2e-16), so a `double` shader silently computed WRONG values while
// producing naga-valid output. It must honest-error instead of downgrading. (The
// frontend honest-errors double; this is the external-SPIR-V path via spirvToWGSL.)
test "wgsl: double (64-bit float) honest-errors instead of silently downgrading (#170)" {
    const spirv = compileToSpirv("double_type",
        \\#version 450
        \\layout(location = 0) in float x;
        \\layout(location = 0) out vec4 o;
        \\void main() { double d = double(x) * 1.0e15lf; o = vec4(float(d)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedDoubleType, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: WGSL has no 64-bit integer (i64/u64 / GLSL int64_t/uint64_t) in core. Like
// the f64 case, `wgslType` collapsed every OpTypeInt to i32/u32 regardless of width,
// so an `int64_t` shader silently truncated to 32 bits (e.g. a 1e12 constant cannot
// fit in i32) while producing naga-valid output = silent-wrong. It must honest-error.
// (umulExtended/imulExtended do NOT introduce an OpTypeInt-64 type — their result is
// two 32-bit halves — so this guard is independent of that honest-error path.)
test "wgsl: int64 (64-bit integer) honest-errors instead of silently downgrading (#170)" {
    const spirv = compileToSpirv("int64_type",
        \\#version 450
        \\#extension GL_ARB_gpu_shader_int64 : require
        \\layout(location = 0) flat in int x;
        \\layout(location = 0) out vec4 o;
        \\void main() { int64_t a = int64_t(x) * 1000000000000L; o = vec4(float(a)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedInt64Type, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: GLSL `bitCount` ALWAYS returns a signed int (genIType), even for an unsigned
// argument, but WGSL `countOneBits(e)` returns the ARGUMENT's type. For a `uvec3`
// argument the result was emitted as `let v: vec3i = countOneBits(v)` — but
// countOneBits(vec3u) is vec3u, so naga rejected the mismatch ("the type of `v` is
// expected to be vec3<i32>, but got vec3<u32>"). Wrap the call in the (signed) result
// type. (Signed args make it an identity wrap; reverseBits is unaffected because GLSL
// bitfieldReverse keeps the argument's signedness, matching WGSL.)
test "wgsl: bitCount on an unsigned vector wraps to the signed result type (#170)" {
    const spirv = compileToSpirv("bitcount_uvec",
        \\#version 450
        \\layout(location = 0) flat in uvec3 v;
        \\layout(location = 0) out vec4 o;
        \\void main() { ivec3 c = bitCount(v); o = vec4(vec3(c), 1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "countOneBits");
    try nagaValidateOrSkip(wgsl, "bitcount-uvec");
}

// #170: OpBitFieldSExtract / OpBitFieldUExtract / OpBitFieldInsert result ids were
// NOT registered in the shared collectNames table (resultIdFromOp listed BitReverse
// and BitCount but omitted the three bitfield ops), so the result was UNNAMED. The
// extractBits emit then used the fallback name `v` while the consuming OpStore used a
// DIFFERENT fallback (`0`) — producing `r = 0;` (a scalar `0` stored into a `vec2i`
// var = naga store-type mismatch, AND the bitfield result silently dropped). Naming
// the result makes both sites agree.
test "wgsl: bitfieldExtract on a vector stores the result, not 0 (#170)" {
    const spirv = compileToSpirv("bitfield_extract_vec",
        \\#version 450
        \\layout(location = 0) flat in ivec2 k;
        \\layout(location = 0) out vec4 o;
        \\void main() { ivec2 r = bitfieldExtract(k, 2, 5); o = vec4(vec2(r), 0.0, 1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "extractBits(");
    try nagaValidateOrSkip(wgsl, "bitfield-extract-vec");
}

// #170: WGSL `@builtin(sample_index)` MUST be `u32`, but GLSL `gl_SampleID` is signed
// `int`, so glslpp emitted `@builtin(sample_index) gl_SampleID: i32` — naga rejects
// ("Built-in type for SampleIndex is invalid. Found Sint"). The existing needs_u32
// coercion (already applied to vertex_index/instance_index, which WGSL also requires
// to be u32) must also cover sample_index: declare the entry param `u32` and coerce
// to the signed name for the body.
test "wgsl: gl_SampleID (sample_index) entry param is u32, not i32 (#170)" {
    const spirv = compileToSpirv("sample_id",
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(float(gl_SampleID)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "@builtin(sample_index)");
    try nagaValidateOrSkip(wgsl, "sample-id");
}

// #170: WGSL has NO `primitive_id` built-in — the core fragment-input builtins are
// only position/front_facing/sample_index/sample_mask. glslpp mapped gl_PrimitiveID →
// `@builtin(primitive_id)`, which naga rejects ("unknown builtin: `primitive_id`") =
// silent-wrong (non-validating WGSL). It must honest-error instead.
test "wgsl: gl_PrimitiveID honest-errors (WGSL has no primitive_id builtin) (#170)" {
    const spirv = compileToSpirv("primitive_id",
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(float(gl_PrimitiveID)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: dynamically indexing a `const` array at TWO sites makes glslang emit two
// distinct OpVariables that share the SAME OpName string ("indexable", the local
// copy it makes per access). glslpp named both `indexable`, so the WGSL had two
// `var indexable: array<f32,5>;` declarations — naga rejects ("redefinition of
// `indexable`") = silent-wrong. Function-local var names are now deduped (the second
// becomes `indexable_1`) and the names map updated so its uses resolve to it.
test "wgsl: duplicate glslang OpName for two local vars is deduped (no redefinition) (#170)" {
    const spirv = compileToSpirv("dup_local_name",
        \\#version 450
        \\layout(location = 0) flat in int i;
        \\layout(location = 0) out vec4 o;
        \\const float weights[5] = float[5](0.1, 0.2, 0.4, 0.2, 0.1);
        \\void main() {
        \\    float s = 0.0;
        \\    for (int j = 0; j < 5; j++) s += weights[j];
        \\    o = vec4(weights[clamp(i, 0, 4)], s, 0.0, 1.0);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "dup-local-name");
}

// #170: WGSL entry-point inputs/outputs may ONLY be numeric scalars or vectors —
// a matrix at a @location is rejected by naga ("The type [N] cannot be used for
// user-defined entry point inputs or outputs. Only numeric scalars and vectors
// are allowed."). glslpp's generic input-param emitter printed a top-level matrix
// varying as `@location(0) m: mat4x4<f32>` = silent-wrong (non-validating WGSL).
// (spirv-cross flattens a matrix varying into N column @locations; glslpp does not
// reconstruct that, and its sibling guards already honest-error on a matrix MEMBER
// at a @location, so a top-level matrix input must honest-error too, not emit
// invalid WGSL.) The frontend never emits a matrix stage input; this is the
// external-SPIR-V path via spirvToWGSL.
test "wgsl: matrix-typed stage input honest-errors (only scalars/vectors at @location) (#170)" {
    const spirv = compileToSpirv("matrix_input",
        \\#version 450
        \\layout(location = 0) in mat4 m;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = m * vec4(1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: same rule as the matrix-input case — an ARRAY at a @location is equally
// invalid WGSL entry IO. A vertex `in vec4 a[2];` attribute is emitted by glslang
// as a single TypeArray input var (occupying locations 0,1); glslpp's generic
// input-param emitter would otherwise print `@location(0) a: array<vec4<f32>, 2>`,
// which naga rejects. It must honest-error (covers the TypeArray arm of the guard).
test "wgsl: array-typed stage input honest-errors (only scalars/vectors at @location) (#170)" {
    const spirv = compileVertToSpirv("array_input",
        \\#version 450
        \\layout(location = 0) in vec4 a[2];
        \\void main() { gl_Position = a[0] + a[1]; }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: the OUTPUT-side symmetry of the array-input guard above. A top-level
// (non-block, non-struct) array OUTPUT at a @location is equally invalid WGSL
// entry IO. A vertex `out vec4 a[2];` varying is emitted by glslang as a single
// TypeArray output var; the vertex output-assembly path flattens a top-level
// MATRIX into N column @locations but deliberately does NOT flatten a top-level
// array (that would require runtime reconstruction glslpp doesn't implement), so
// without the guard the generic emitter would append `@location(0) a: array<...>`
// to VertexOutput, which naga rejects ("Only numeric scalars and vectors are
// allowed"). It must honest-error, consistent with the input guard and the
// existing matrix-MEMBER guards. The detail-string check pins this to the array
// guard rather than any other error.UnsupportedOp path.
test "wgsl: array-typed stage output honest-errors (only scalars/vectors at @location) (#170)" {
    const spirv = compileVertToSpirv("array_output",
        \\#version 450
        \\layout(location = 0) out vec4 a[2];
        \\void main() { a[0] = vec4(1.0); gl_Position = vec4(0.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "array output") != null);
}

// #170: WGSL's reserved-word rename list covered keywords and predeclared TYPE
// names but MISSED predeclared builtin FUNCTION names like `bitcast` and `select`.
// `bitcast` is a legal GLSL identifier (GLSL has no such builtin), so a GLSL
// `float bitcast = ...;` was emitted verbatim as `var bitcast: f32;` — and since
// glslpp lowers floatBitsToInt() to the WGSL `bitcast<i32>(...)` builtin, the
// shadowing variable made naga reject the call ("local declaration cannot be
// called") = silent-wrong. The builtin-function names must be renamed too.
test "wgsl: a variable named `bitcast` is renamed so the bitcast<T>() builtin still resolves (#170)" {
    const spirv = compileToSpirv("clash_bitcast",
        \\#version 450
        \\layout(location = 0) in vec4 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float bitcast = v.x;
        \\    int x = floatBitsToInt(bitcast);
        \\    o = vec4(intBitsToFloat(x), bitcast, 0.0, 1.0);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // The bitcast<i32>() builtin call must survive (the variable is what gets renamed).
    try assertContains(wgsl, "bitcast<i32>");
    try nagaValidateOrSkip(wgsl, "clash-bitcast");
}

// #170: sibling of the bitcast case — a GLSL variable named `select` collides with
// the WGSL `select(...)` builtin that glslpp emits for OpSelect (here from a
// `mix(a, b, bool)`). The variable must be renamed (→ `select_`) so the builtin
// call still resolves; otherwise naga rejects ("local declaration cannot be called").
test "wgsl: a variable named `select` is renamed so the select() builtin still resolves (#170)" {
    const spirv = compileToSpirv("clash_select",
        \\#version 450
        \\layout(location = 0) in vec4 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    bool select = v.x > 0.0;
        \\    float r = mix(v.y, v.z, select);
        \\    o = vec4(r, float(select), 0.0, 1.0);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "select(");
    try nagaValidateOrSkip(wgsl, "clash-select");
}

// #170: the texture-builtin extension of the bitcast/select rename. The WGSL
// texture builtins (textureSample, textureLoad, textureDimensions, …) have GLSL
// counterparts with DIFFERENT names (texture, texelFetch, textureSize), so a GLSL
// variable can legally be named the WGSL one. glslpp emits the builtin as a call
// (`textureLoad(...)`), so a `vec4 textureLoad = texelFetch(...)` was emitted as
// `var textureLoad: vec4f;` and then the texelFetch->textureLoad() call made naga
// reject ("local declaration cannot be called") = silent-wrong. These names were
// excluded from the #336 fix and are now reserved too.
test "wgsl: a variable named `textureLoad` is renamed so the textureLoad() builtin still resolves (#170)" {
    const spirv = compileToSpirv("clash_textureload",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) flat in ivec2 p;
        \\layout(location = 0) out vec4 o;
        \\void main() { vec4 textureLoad = texelFetch(s, p, 0); o = textureLoad; }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureLoad(");
    try nagaValidateOrSkip(wgsl, "clash-textureload");
}

// #170: sibling — a query-class texture builtin. `ivec2 textureDimensions =
// textureSize(s,0)` collided with the WGSL `textureDimensions(...)` call.
test "wgsl: a variable named `textureDimensions` is renamed so the builtin still resolves (#170)" {
    const spirv = compileToSpirv("clash_texturedims",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D s;
        \\layout(location = 0) out vec4 o;
        \\void main() { ivec2 textureDimensions = textureSize(s, 0); o = vec4(float(textureDimensions.x)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, "textureDimensions(");
    try nagaValidateOrSkip(wgsl, "clash-texturedims");
}

// #170: an array of UBO blocks (`uniform U { vec4 color; } us[3];`) is wrapped by
// glslpp as `struct us_wrapper { values: array<U, 3> }` + `var<uniform> us:
// us_wrapper` (the float/int bare-array path widens to vec4 with a `._wrapped_`
// field; the struct-array case falls to a sibling branch). The float/int path
// remapped the base name so accesses go through the wrapper field, but the
// struct-array fallback did NOT — so the body emitted `us[i].color` instead of
// `us.values[i].color`, which naga rejects ("invalid field accessor `color`") =
// silent-wrong. The fallback must apply the same `.values` base-name remap.
test "wgsl: array of UBO blocks accesses through the wrapper field (#170)" {
    const spirv = compileToSpirv("ubo_block_array",
        \\#version 450
        \\layout(std140, binding = 0) uniform U { vec4 color; } us[3];
        \\layout(location = 0) flat in int k;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = us[0].color + us[1].color + us[k % 3].color; }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    // Access must go through the wrapper field, not bare `us[i]`.
    try assertContains(wgsl, ".values[");
    try nagaValidateOrSkip(wgsl, "ubo-block-array");
}

// #170: an SSBO array length (`values.length()` → OpArrayLength → WGSL
// `arrayLength(&Data_data.values)`) was emitted with the bare fallback name `v`
// because OpArrayLength was MISSING from the shared resultIdFromOp table — so its
// result id was never registered in the names map. With TWO `.length()` calls in
// one scope, both results fell back to `let v`, producing `redefinition of `v`` =
// silent-wrong (naga reject). Registering OpArrayLength's result id gives each
// call a unique `v{id}` name. (Same class as #327's missing bitfield ops.)
test "wgsl: two arrayLength() calls get distinct names (no redefinition) (#170)" {
    const wgsl = compileCompToWgsl(
        \\#version 450
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer Data { float values[]; };
        \\void main() {
        \\    uint i = gl_GlobalInvocationID.x;
        \\    if (i >= values.length()) return;
        \\    uint j = i ^ 1u;
        \\    if (j < values.length()) { values[i] = values[j]; }
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try assertContains(wgsl, "arrayLength(");
    try nagaValidateOrSkip(wgsl, "arraylength-dup");
}

// #170: an ARRAYED storage image (image2DArray) imageLoad/imageStore takes the
// array layer as the LAST coordinate component in GLSL, but WGSL takes it as a
// SEPARATE argument: `textureLoad(t, coord.xy, coord.z)`. glslpp emitted
// `textureLoad(uArr, vec3<i32>(...))` (the layer folded into the coordinate) →
// naga "wrong number of arguments: expected 3, found 2" = silent-wrong. The
// layer must be split out for both textureLoad and textureStore.
test "wgsl: arrayed storage image load/store splits the array layer arg (#170)" {
    const spirv = compileToSpirv("storage_image_array",
        \\#version 450
        \\layout(rgba8, binding = 0) uniform image2DArray uArr;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 a = imageLoad(uArr, ivec3(1, 2, 3));
        \\    imageStore(uArr, ivec3(4, 5, 6), a);
        \\    o = a;
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try assertContains(wgsl, ".xy,"); // spatial coord split from the layer
    try assertContains(wgsl, ".z)"); // the split-out array layer argument
    try nagaValidateOrSkip(wgsl, "storage-image-array");
}

// #170: a MULTISAMPLED storage image (image2DMS) has NO WGSL representation —
// there is no multisampled storage texture type. glslpp silently dropped the MS
// aspect (emitting a plain texture_storage_2d) AND the sample index = silent-wrong.
// It must honest-error instead.
test "wgsl: multisampled storage image honest-errors (no WGSL MS storage texture) (#170)" {
    const spirv = compileToSpirv("storage_image_ms",
        \\#version 450
        \\layout(rgba8, binding = 0) uniform image2DMS uImage;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = imageLoad(uImage, ivec2(1, 2), 2); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedOp, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: a NESTED array of samplers (`sampler1D s[2][2]`) is doubly-unrepresentable
// in core WGSL (no sampler arrays at all, let alone nested). The hasOpaqueArrayResource
// guard checked only ONE array level, so the array-of-array-of-sampledimage slipped
// past: glslpp emitted sample calls referencing an UNDECLARED `s` and a malformed
// `s[0][1]_sampler` (naga "expected )") = silent-wrong. The guard must unwrap EVERY
// array level and honest-error like the single-level form already does.
test "wgsl: nested sampler array honest-errors (#170)" {
    const spirv = compileToSpirv("nested_sampler_array",
        \\#version 450
        \\layout(binding = 0) uniform sampler1D s[2][2];
        \\layout(location = 0) flat in float c;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = texture(s[0][1], c) + texture(s[1][0], c); }
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    try std.testing.expectError(error.UnsupportedSamplerArray, glslpp.spirvToWGSL(alloc, spirv, .{}));
}

// #170: an SSBO that is an ARRAY of blocks whose struct holds a runtime-sized
// array (`buffer SSBO { vec4 data[]; } ssbos[2];` → `array<SSBO, 2>` where SSBO is
// `{ data: array<vec4f> }`) is unrepresentable in core WGSL — a runtime-sized
// array cannot nest inside a fixed-size array (naga "Base type for the array is
// invalid"), and there is no core-WGSL dynamically-indexed array of runtime-sized
// storage buffers. glslpp emitted the naga-rejected nesting = silent-wrong; it
// must honest-error instead. (A PLAIN SSBO with a runtime array still works.)
test "wgsl: array of SSBO blocks with a runtime-array member honest-errors (#170)" {
    try std.testing.expectError(error.UnsupportedOp, compileCompToWgsl(
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer SSBO { vec4 data[]; } ssbos[2];
        \\void main() {
        \\    ssbos[1].data[gl_GlobalInvocationID.x] = ssbos[0].data[gl_GlobalInvocationID.x];
        \\}
    ));
    // Pin the error to THIS guard (not some other UnsupportedOp path).
    const detail = glslpp.wgslLastErrorDetail() orelse return error.MissingErrorDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "runtime-sized array member") != null);
}

// #170: an SSBO that is an ARRAY of blocks whose struct has only FIXED members
// (`buffer B { vec4 a; vec4 b; } bufs[2];`) IS representable as
// `var<storage, read_write> bufs: array<B, 2>`. But glslang's legacy SPIR-V
// encodes such an SSBO as the `Uniform` storage class with `BufferBlock` on the
// inner STRUCT — and the variable's pointee is the ARRAY, not the struct, so the
// `hasDec(array, .buffer_block)` check returned false → is_ssbo=false → the var
// went through the array-of-UBO wrapper path and was emitted READ-ONLY as
// `var<uniform>`. A store `bufs[1].a = ...` then made naga reject ("writing to
// this location is not permitted") = silent-wrong. Must emit a writable storage
// buffer. (Distinct from the runtime-array case above, which is genuinely
// unrepresentable and correctly honest-errors.) Uses glslang SPIR-V because
// glslpp's own frontend emits the StorageBuffer class, which never hit the bug.
test "wgsl: array of SSBO blocks with only fixed members emits writable storage (#170)" {
    const spirv = compileToSpirv("ssbo_array_fixed",
        \\#version 450
        \\layout(std430, binding = 0) buffer B { vec4 a; vec4 b; } bufs[2];
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    bufs[1].a = bufs[0].b;
        \\    o = bufs[1].a;
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
    defer alloc.free(wgsl);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<storage") != null);
    try std.testing.expect(std.mem.indexOf(u8, wgsl, "var<uniform") == null);
    try nagaValidateOrSkip(wgsl, "ssbo-array-fixed-members");
}

// #170: a UNIFORM block whose member offsets are not the WGSL-natural ones —
// a NESTED struct (`Foo foo`) and an array member follow std140 rules that round
// a struct/array member up to a 16-byte boundary. glslpp emitted the struct with
// NO @align/@size attributes, so naga computes the natural offset (foo at byte 8,
// right after two i32s) and rejects: "The struct member offset 8 is not a multiple
// of the required alignment 16" on `var<uniform>` — silent-wrong. The fix reads the
// SPIR-V member Offset decorations and emits @align/@size so the WGSL layout matches
// (foo lands at offset 16). STORAGE blocks tolerate the natural layout, so only the
// uniform path was rejected. (tests/spirv-cross/enhanced-layouts.comp, naga baseline reject.)
test "wgsl: uniform block with nested-struct/array member offsets validates (#170)" {
    const wgsl = try compileCompToWgsl(
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\struct Foo { int a; int b; int c; };
        \\layout(std140, binding = 0) uniform UBO {
        \\    layout(offset = 4) int a;
        \\    layout(offset = 8) int b;
        \\    layout(offset = 16) Foo foo;
        \\    layout(offset = 48) int c[8];
        \\} ubo;
        \\layout(std430, binding = 1) buffer SSBO { int out_b; } ssbo;
        \\void main() { ssbo.out_b = ubo.b; }
    );
    defer alloc.free(wgsl);
    // The nested struct member must carry an @align(16) so naga places it at the
    // SPIR-V offset (16), not the natural 8.
    try assertContains(wgsl, "@align(16)");
    try nagaValidateOrSkip(wgsl, "uniform-nested-offsets");
}

// #170: a 2-row matrix (matCx2) in a UNIFORM block is unrepresentable in core
// WGSL — std140 packs each column on a 16-byte stride, but WGSL's matCx2<f32> has
// a fixed 8-byte column stride and there is NO matrix-stride attribute to override
// it. naga ACCEPTS the mis-strided matrix (every column past the first reads from
// the wrong byte = silent-wrong). The faithful @align/@size offset pass would
// otherwise UNMASK this: a UBO formerly rejected for a nested-member offset now
// validates with a silently-wrong matrix. So it must honest-error instead. matCx3/
// matCx4 (16-byte column stride) and storage-block matrices (std430 stride 8 ==
// WGSL 8) are unaffected.
test "wgsl: 2-row matrix in a uniform block honest-errors (#170)" {
    try std.testing.expectError(error.UnsupportedOp, compileToWgsl(
        \\#version 450
        \\layout(std140, binding = 0) uniform UBO { mat2 m2; vec4 tail; } ubo;
        \\layout(location = 0) out vec4 o;
        \\void main() { vec2 r = ubo.m2 * ubo.tail.xy; o = vec4(r, 0.0, 0.0) + ubo.tail; }
    ));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.MissingErrorDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "2-row matrix") != null);
}

// #170 guard scope: a 3-row matrix (mat3) in a uniform block IS representable —
// its std140 16-byte column stride matches WGSL's mat3x3<f32> column stride (16) —
// so it must NOT be caught by the matCx2 honest-error and must validate with naga.
test "wgsl: 3-row matrix in a uniform block validates (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(std140, binding = 0) uniform UBO { mat3 m3; vec4 tail; } ubo;
        \\layout(location = 0) out vec4 o;
        \\void main() { vec3 r = ubo.m3 * ubo.tail.xyz; o = vec4(r, 0.0) + ubo.tail; }
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "uniform-mat3");
}

// #170: the matCx2 guard must unwrap EVERY array level — a multidimensional matrix
// array (`mat2 m[2][3]`) is nested OpTypeArrays in SPIR-V. A one-level unwrap would
// leave the type an array, miss the inner matrix, and let the silently-mis-strided
// matCx2 slip through. Must honest-error like the scalar/single-array forms.
test "wgsl: multidim 2-row matrix array in a uniform block honest-errors (#170)" {
    try std.testing.expectError(error.UnsupportedOp, compileToWgsl(
        \\#version 450
        \\layout(std140, binding = 0) uniform UBO { mat2 m[2][3]; vec4 tail; } ubo;
        \\layout(location = 0) out vec4 o;
        \\void main() { vec2 r = ubo.m[1][2] * ubo.tail.xy; o = vec4(r, 0.0, 0.0) + ubo.tail; }
    ));
    const detail = glslpp.wgslLastErrorDetail() orelse return error.MissingErrorDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "2-row matrix") != null);
}

// #170: a PUSH_CONSTANT block with a std140 sub-16 array member (`float vals[4]`).
// The frontend (codegen.zig) emits Block + member layout (Offset/ArrayStride) only
// for .uniform/.storage_buffer blocks — push-constant blocks were excluded, so the
// `float[4]` member got NO ArrayStride. The WGSL backend's std140 sub-16 widening
// (array<f32,N> → array<vec4<f32>,N> + `.x`) gates on ArrayStride==16, so with the
// stride absent the array stayed `array<f32,4>` (stride 4) → naga "array stride 4
// is not a multiple of the required alignment 16" = silent-wrong. Including
// push-constant in the frontend's Block-layout scan emits the stride so the
// backend widens it. (Named push-constant + anonymous uniform already worked.)
test "wgsl: push-constant std140 array member is widened (#170)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(push_constant, std140) uniform UBO { float ubo[4]; };
        \\layout(location = 0) out float FragColor;
        \\void main() { FragColor = ubo[1]; }
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try assertContains(wgsl, "array<vec4<f32>, 4>"); // widened
    try nagaValidateOrSkip(wgsl, "push-constant-std140-array");
}

// #170: making push-constant blocks Block-decorated (above) means their bool/bvec
// members now need the same bool→uint substitution UBO/SSBO members get — SPIR-V
// forbids OpTypeBool inside a Block. A `bool` member in a push-constant block must
// produce valid output, not an OpTypeBool-in-Block spirv-val violation.
test "wgsl: push-constant block with a bool member is valid (bool→uint) (#170)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(push_constant, std140) uniform PC { bool flag; vec4 color; };
        \\layout(location = 0) out vec4 o;
        \\void main() { o = flag ? color : vec4(0.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "push-constant-bool-member");
}

// #170: GLSL/SPIR-V leave a shift whose amount is >= the operand bit width
// undefined; glslang happily emits e.g. `state >> 63u` on a 32-bit uint
// (rule30.frag). WGSL makes a CONSTANT over-shift a shader-creation error, so
// naga rejects the faithful translation `v >> u32(63u)` at exit 0 = silent-wrong.
// Mask the constant amount to the low bits (& 31) — a no-op for in-range amounts,
// and the same wrap hardware / the HLSL+MSL backends already apply — so the WGSL
// validates instead of being silently rejected.
test "wgsl: constant shift amount >= 32 is masked so naga accepts it (#170)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uint state = uint(uv.x * 64.0);   // runtime, so the shift is not folded
        \\    uint bit = (state >> 63u) & 1u;   // const over-shift by 63 on a 32-bit uint
        \\    o = vec4(float(bit));
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try assertContains(wgsl, "u32(31u)"); // 63 & 31 = 31
    try nagaValidateOrSkip(wgsl, "const-overshift-masked");
}

// #170: OpShiftRightArithmetic (signed `>>`) routed through the generic emitBinOp,
// which applied NEITHER the u32 amount cast the logical-shift arm emits NOR the
// constant over-shift mask. naga then rejects the const over-shift (creation error)
// — and even an in-range signed shift would be rejected for the i32-typed amount
// (`>>` needs a u32/vecN<u32> shift count). The arithmetic-shift arm must mask +
// u32-cast exactly like the logical arms. As of the signedness fix glslpp's
// frontend now emits OpShiftRightArithmetic (195) DIRECTLY for a signed `>>` (it
// previously lowered every `>>` to ShiftRightLogical) — so this exercises the full
// frontend→WGSL path with no opcode rewrite.
test "wgsl: signed arithmetic constant over-shift is masked + u32-cast (#170)" {
    const source: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    int state = int(uv.x * 64.0);   // runtime, so the shift is not folded
        \\    int r = state >> 40;             // const over-shift by 40 on a 32-bit signed int
        \\    o = vec4(float(r));
        \\}
    ;
    const spirv = glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment }) catch return error.SkipZigTest;
    defer alloc.free(spirv);
    // The signedness fix lowers a signed `>>` to OpShiftRightArithmetic (195)
    // directly — assert exactly one, and NO logical shift (194) for this signed op.
    try std.testing.expectEqual(@as(u32, 1), countSpirvOpcode(spirv, 195));
    try std.testing.expectEqual(@as(u32, 0), countSpirvOpcode(spirv, 194));
    const wgsl = glslpp.spirvToWGSL(alloc, spirv, .{}) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try assertContains(wgsl, "u32(8u)"); // 40 & 31 = 8
    try nagaValidateOrSkip(wgsl, "signed-const-overshift-masked");
}

// #170: a VECTOR base shifted by a constant COMPOSITE amount (`uvec4 >> uvec4(40u,…)`).
// constIntValue returns null for an OpConstantComposite, so the amount escaped the
// scalar over-shift mask and naga rejects the per-component const over-shift just like
// the scalar case. Each component must be masked & 31.
test "wgsl: vector constant-composite over-shift masks each component (#170)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in uvec4 a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uvec4 r = a >> uvec4(40u, 33u, 32u, 5u);  // const composite over-shift, runtime base
        \\    o = vec4(float(r.x));
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    // 40&31=8, 33&31=1, 32&31=0, 5&31=5
    try assertContains(wgsl, "vec4<u32>(8u, 1u, 0u, 5u)");
    try nagaValidateOrSkip(wgsl, "vec-composite-overshift-masked");
}

// #170: shifts re-emitted in the switch/loop REPLAY path (emitSimpleInstruction)
// went through the generic emitBinOp via getBinOpSymbol — neither masked nor
// u32-cast — so a constant over-shift inside a switch-case body emitted
// naga-rejected WGSL (`base >> 40u`). The replay path must delegate to emitShift
// just like the main emit path. (A shift in a loop body lands in the MAIN path;
// a switch-case body lands here.)
test "wgsl: switch-case-body constant over-shift is masked (#170 replay path)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int sel;
        \\layout(location = 1) flat in uint base;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    uint r = 0u;
        \\    switch (sel) {
        \\        case 0: r = base >> 40u; break;   // const over-shift in a switch case
        \\        case 1: r = base << 33u; break;
        \\        default: r = base; break;
        \\    }
        \\    o = vec4(float(r));
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try assertContains(wgsl, "u32(8u)"); // 40 & 31 = 8
    try assertContains(wgsl, "u32(1u)"); // 33 & 31 = 1
    try nagaValidateOrSkip(wgsl, "switch-case-overshift-masked");
}

// #170: a std430 (or scalar-layout) push-constant / uniform block with a sub-16
// array member packs the array TIGHTLY (`float Arr[4]` → ArrayStride 4). WGSL's
// uniform address space requires every array element stride to be a multiple of
// 16, and glslpp cannot widen the array to vec4 without reading WRONG DATA from
// the host (the host packs at 0,4,8,12 not 0,16,32,48). So the block emitted as
// `var<uniform>` is naga-rejected ("array stride 4 is not a multiple of 16") at
// exit 0 = silent-wrong (tests/spirv-cross/push-constant.flatten.vert). It is
// genuinely unrepresentable in core WGSL uniform space → honest-error instead.
test "wgsl: std430 push-constant block with a sub-16 array member honest-errors (#170)" {
    try std.testing.expectError(error.UnsupportedOp, compileToWgsl(
        \\#version 450
        \\layout(push_constant, std430) uniform PC { float Arr[4]; } pc;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(pc.Arr[2]); }
    ));
    // Pin the error to THIS guard (not some other UnsupportedOp path).
    const detail = glslpp.wgslLastErrorDetail() orelse return error.MissingErrorDetail;
    try std.testing.expect(std.mem.indexOf(u8, detail, "stride") != null);
}

// #170: OpCompositeConstruct's "all operands identical" broadcast simplification
// (`vec3(x,x,x)` → `vec3f(x)`) is a valid scalar SPLAT for a VECTOR result, but a
// MATRIX has no single-argument constructor — `mat3(v,v,v)` collapsed to the
// naga-rejected cast `mat3x3f(v)` ("cannot cast a vec3<f32> to a mat3x3<f32>") at
// exit 0 = silent-wrong. A matrix built from identical columns must keep every
// column argument. (Partially-distinct columns already took the general path.)
test "wgsl: matrix from identical columns keeps every column arg (#170)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec3 v;
        \\layout(location = 0) out vec4 o;
        \\void main() { mat3 m = mat3(v, v, v); o = vec4(m * vec3(1.0), 1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try assertContains(wgsl, "mat3x3f(v, v, v)"); // all three columns, not mat3x3f(v)
    try nagaValidateOrSkip(wgsl, "matrix-identical-columns");
}

// #170: a matrix rebuilt from another matrix's COLUMNS (`mat2(m[0], m[1])`) — the
// columns are CompositeExtracts — previously hit the leading-extract-collapse path
// (a vector-only simplification) and emitted the matrix-swizzle `mat2x2f(m.xy)`,
// which naga rejects (a swizzle is not valid on a matrix) = silent-wrong. Matrix
// results must keep per-column args: `mat2x2f(m[0], m[1])`.
test "wgsl: matrix rebuilt from another matrix's columns keeps per-column args (#170)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec2 a;
        \\layout(location = 1) in vec2 b;
        \\layout(location = 0) out vec4 o;
        \\void main() { mat2 m = mat2(a, b); mat2 n = mat2(m[0], m[1]); o = vec4(n * vec2(1.0), 0.0, 1.0); }
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    // The rebuilt matrix keeps per-column index args (`mNxN(m[0], m[1])`), not a
    // matrix-swizzle collapse. naga validation is the real silent-wrong guard.
    try assertContains(wgsl, "[0], ");
    try nagaValidateOrSkip(wgsl, "matrix-from-matrix-columns");
}

// #170 (no-panic): selection-merge phis are collected into a per-merge-label list
// pre-sized to capacity 2, but a single merge accumulates one entry per
// (value,predecessor) pair across ALL phis at that label — an if/else assigning
// three variables yields 3 phis × 2 predecessors = 6 entries, and a multi-case
// switch yields a phi pair per case. The old `appendAssumeCapacity` overflowed
// the capacity-2 list and PANICKED ("reached unreachable code") on these common
// shapes (phi3_vars/phi4_types/switch_var/switch_8case/... in the corpus). The
// collector must grow the list. This shader (3 phis at one merge) reproduces it.
test "wgsl: multi-variable if/else merge does not overflow the phi list (#170 no-panic)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float a, b, c;
        \\    if (t < 0.5) { a = 1.0; b = 2.0; c = 3.0; } else { a = 4.0; b = 5.0; c = 6.0; }
        \\    o = vec4(a, b, c, 1.0);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "phi-merge-no-overflow");
}

// #170 (no-panic): the loop-merge twin of the above. Loop-header phi updates are
// collected into one list across ALL loops in the function, pre-sized to capacity
// 8; four loops each carrying three variables = 12 entries overflowed the assumed
// capacity and panicked. The collector must grow.
test "wgsl: many loop-carried phis across loops do not overflow the phi-update list (#170 no-panic)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int n;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float a = 0.0, b = 0.0, c = 0.0;
        \\    for (int i = 0; i < n; i++) { a += 1.0; b += 2.0; c += 3.0; }
        \\    for (int i = 0; i < n; i++) { a += 1.0; b += 2.0; c += 3.0; }
        \\    for (int i = 0; i < n; i++) { a += 1.0; b += 2.0; c += 3.0; }
        \\    for (int i = 0; i < n; i++) { a += 1.0; b += 2.0; c += 3.0; }
        \\    o = vec4(a, b, c, 1.0);
        \\}
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "loop-phi-no-overflow");
}

// #170 (no-panic): the function-id list was pre-sized to capacity 8; a module with
// more than 8 functions (entry + >8 helpers) overflowed the assumed capacity and
// panicked. The collector must grow.
test "wgsl: a module with more than 8 functions does not overflow the func-id list (#170 no-panic)" {
    const wgsl = compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\float f1(float x){return x+1.0;} float f2(float x){return x+2.0;}
        \\float f3(float x){return x+3.0;} float f4(float x){return x+4.0;}
        \\float f5(float x){return x+5.0;} float f6(float x){return x+6.0;}
        \\float f7(float x){return x+7.0;} float f8(float x){return x+8.0;}
        \\float f9(float x){return x+9.0;} float f10(float x){return x+10.0;}
        \\void main(){ o = vec4(f1(t)+f2(t)+f3(t)+f4(t)+f5(t)+f6(t)+f7(t)+f8(t)+f9(t)+f10(t)); }
    ) catch return error.SkipZigTest;
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "many-functions-no-overflow");
}

// #170 (no silent-wrong): an unresolved `#include` was silently skipped (the
// preprocessor swallowed error.FileNotFound and continued at exit 0), so a shader
// referencing the missing file's symbols compiled to WRONG output (the include's
// declarations just vanished). A missing include must honest-error, like
// glslangValidator/glslc, not be silently dropped.
test "wgsl: an unresolved #include honest-errors instead of being silently skipped (#170)" {
    try std.testing.expectError(error.PreprocessFailed, glslpp.compileToSPIRV(alloc,
        \\#version 450
        \\#include "this_file_does_not_exist_zzz.glsl"
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(1.0); }
    , .{ .stage = .fragment }));
}

// #170: a multi-declarator STRUCT member (`struct Ray { vec3 o, d; };` — two names
// in one declaration) is valid GLSL (glslang accepts it; tests/spirv-cross/
// ray_sphere_test.frag uses it), but glslpp's struct parser read only the first
// name and then required a `;`, so the `, d` tripped it and the whole struct was
// mis-parsed → a downstream InvalidAssignment/TypeMismatch on a valid shader.
// Each comma-separated declarator must register its own member (with its own
// optional array suffix).
test "wgsl: multi-declarator struct member registers every name (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\struct Ray { vec3 oo, dd; };
        \\layout(location = 0) in vec3 c;
        \\layout(location = 0) out vec4 fc;
        \\void main() { Ray r; r.oo = c; r.dd = c * 2.0; fc = vec4(r.oo - r.dd, 1.0); }
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "multi-decl-struct-member");
}

// #170: the same multi-declarator support is needed for UNIFORM BLOCK members
// (`uniform U { vec2 a, b; };`), which share the parser path's single-name limit.
test "wgsl: multi-declarator uniform block member registers every name (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec4 a, b; } u;
        \\layout(location = 0) out vec4 fc;
        \\void main() { fc = u.a + u.b; }
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "multi-decl-ubo-member");
}

// #170: a multi-declarator LOCAL of a user STRUCT type without initializers
// (`S a, b;`) was mis-routed in parseStatement — the struct-decl dispatch only
// recognized a name followed by `=`, `;`, or `[`, not `,`, so the second name
// was dropped (UndeclaredIdentifier on `b`) on valid GLSL (glslang accepts it).
// Built-in-typed multi-declarator locals (`float a, b;`) already worked.
test "wgsl: multi-declarator local of a struct type registers every name (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\struct S { float x; };
        \\layout(location = 0) out vec4 o;
        \\void main() { S a, b, c; a.x = 1.0; b.x = 2.0; c.x = 3.0; o = vec4(a.x, b.x, c.x, 1.0); }
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "multi-decl-struct-local");
}

// #170: an unsized local array with a sized initializer (`float a[] = float[](1,
// 2, 3, 4);`) is valid GLSL — glslang infers the length from the initializer.
// glslpp left the declared type unsized (size 0) so it mismatched the size-4
// initializer (TypeMismatch) on a valid shader. Infer the length from the init.
test "wgsl: unsized local array infers its length from the initializer (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float a[] = float[](1.0, 2.0, 3.0, 4.0);
        \\    o = vec4(a[0], a[1], a[2], a[3]);
        \\}
    );
    defer alloc.free(wgsl);
    try assertContains(wgsl, "array<f32, 4>"); // length inferred as 4
    try nagaValidateOrSkip(wgsl, "unsized-array-infer-length");
}

// #170: the SIZED counterpart hit the same array-extract→swizzle silent-wrong —
// `float a[4] = float[](...); vec4(a[0],a[1],a[2],a[3])` emitted `vec4f(a.xyzw)`
// (a swizzle on an array, naga-rejected) at exit 0. The elements must stay
// per-index, not collapse to a swizzle.
test "wgsl: vecN from array elements stays per-index, not an array swizzle (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float a[4] = float[](1.0, 2.0, 3.0, 4.0);
        \\    o = vec4(a[0], a[1], a[2], a[3]);
        \\}
    );
    defer alloc.free(wgsl);
    try assertNotContains(wgsl, ".xyzw"); // no swizzle on an array
    try nagaValidateOrSkip(wgsl, "array-elements-no-swizzle");
}

// #170: a vector constructor that TRUNCATES a larger vector (`vec3(aVec4)` →
// take the first 3 components) is valid GLSL, but glslpp had no `arg_n > n` case
// in the single-arg vector constructor — the vec4 fell into the scalar-splat
// path, emitting `composite_construct %float %vec4` (invalid SPIR-V) + splat, so
// every backend produced `vec3(x,x,x)` and naga rejected the WGSL. The first n
// components must be taken.
test "wgsl: vector constructor truncates a larger vector, not splat (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec4 v;
        \\layout(location = 0) out vec4 o;
        \\void main() { vec3 b = vec3(v); vec2 c = vec2(v); o = vec4(b.xy + c, b.z, 1.0); }
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "vector-ctor-truncate");
}

// #170: cross-element-type truncation must convert per component — `ivec2(vec4)`
// (float→int) and `bvec3(vec4)` (float→bool via `!= 0`, since there is no
// to-bool conversion tag). The bool case previously built a bvec from float
// operands = invalid SPIR-V.
test "wgsl: cross-type vector truncation converts each component (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec4 v;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    ivec2 i = ivec2(v);
        \\    bvec3 b = bvec3(v);
        \\    o = vec4(float(i.x), b.x ? 1.0 : 0.0, b.y ? 0.5 : 0.0, b.z ? 0.25 : 0.0);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "cross-type-vector-truncate");
}

// #170: matrix EXPANSION — `mat4(aMat3)` places the mat3 in the top-left and
// fills the rest from the identity (valid GLSL). glslpp's matrix-from-matrix
// path only handled shrink/equal; for expansion it extracted a source column
// that doesn't exist (`OpCompositeExtract ... 3` from a 3-column matrix) and
// used too-short columns — invalid SPIR-V on a valid shader. (Shrink
// `mat3(mat4)` already worked and must stay working.)
test "wgsl: matrix expansion mat4(mat3) fills from identity, not OOB (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec3 a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat3 m = mat3(a, a.yzx, a.zxy);
        \\    mat4 n = mat4(m);      // expand: top-left = m, rest = identity
        \\    mat3 s = mat3(n);      // shrink back (regression guard)
        \\    o = vec4(n[3] + vec4(s[0], 1.0));
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "matrix-expand-mat4-from-mat3");
}

// #170: GLSL applies implicit scalar conversion when a non-literal argument's type
// differs from the parameter's (`f(intVar)` to a float param) and when a returned
// value differs from the function's return type (`return intVar` from a float fn).
// glslpp passed/returned the int id unconverted → an FMul/composite on an int
// operand = invalid SPIR-V on a valid shader (int literals already folded).
test "wgsl: implicit int->float at a function argument is converted (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\float f(float x) { return x + 1.0; }
        \\layout(location = 0) flat in int n;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(f(n)); }
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "implicit-conv-arg");
}

test "wgsl: implicit int->float at a function return is converted (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\float g(int a) { return a; }
        \\layout(location = 0) flat in int n;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(g(n)); }
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "implicit-conv-return");
}

// #170: GLSL also implicitly converts VECTORS at a call boundary (`f(ivec3)` to a
// `vec3` param — glslang accepts it). Routing the arg/return conversion through
// getConversionTag (not a scalar-only ladder) covers these too, so an unconverted
// ivec is never passed to a vec param.
test "wgsl: implicit ivec->vec at a function argument is converted (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\float f(vec3 x) { return x.x + x.y + x.z; }
        \\layout(location = 0) flat in ivec3 n;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(f(n)); }
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "implicit-conv-vec-arg");
}

// #170: a ternary whose arms are ARRAYS (`cond ? arrA : arrB`) lowers to OpSelect
// on an array (valid SPIR-V), but the WGSL backend emitted `select(arrA, arrB,
// cond)` — WGSL's select() rejects aggregates (naga "unexpected argument type for
// select"). The struct case already lowered to a `var` + if/else; arrays must too.
test "wgsl: ternary selecting between arrays lowers to if/else, not select() (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int i;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float a[2] = float[](1.0, 2.0);
        \\    float b[2] = float[](3.0, 4.0);
        \\    o = vec4((i > 0 ? a : b)[i % 2]);
        \\}
    );
    defer alloc.free(wgsl);
    try assertNotContains(wgsl, "select(array"); // no select() on an array
    try nagaValidateOrSkip(wgsl, "ternary-array-select");
}

// #170: a struct used ONLY as a local value (constant-folded to an
// OpCompositeConstruct with no OpVariable — `S a = S(1.0, 2.0); S b = a;`) had its
// `struct S {…}` definition omitted from the WGSL: the local-struct collection
// pass only scanned OpVariable result types, missing SSA struct values. naga then
// rejected "no definition in scope for `S`". Structs in uniforms/params/returns
// were already emitted; this covers the local-value case.
test "wgsl: a struct used only as a local value emits its definition (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\struct S { float x; float y; };
        \\layout(location = 0) flat in int i;
        \\layout(location = 0) out vec4 o;
        \\void main() { S a = S(1.0, 2.0); S b = a; o = vec4(b.x, b.y, 0.0, 1.0); }
    );
    defer alloc.free(wgsl);
    try assertContains(wgsl, "struct S");
    try nagaValidateOrSkip(wgsl, "struct-local-value-decl");
}

// #170: NESTED local-only structs must be emitted in dependency order (inner
// before outer) so naga sees `Inner` declared before `Outer { i: Inner }`.
test "wgsl: nested local-only structs emit inner before outer (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\struct Inner { vec2 p; };
        \\struct Outer { Inner i; float w; };
        \\layout(location = 0) in vec2 t;
        \\layout(location = 0) out vec4 o;
        \\void main() { Outer x = Outer(Inner(t), 3.0); o = vec4(x.i.p, x.w, 1.0); }
    );
    defer alloc.free(wgsl);
    const inner = std.mem.indexOf(u8, wgsl, "struct Inner") orelse return error.InnerMissing;
    const outer = std.mem.indexOf(u8, wgsl, "struct Outer") orelse return error.OuterMissing;
    try std.testing.expect(inner < outer); // inner declared first
    try nagaValidateOrSkip(wgsl, "nested-local-struct-order");
}

// #170: GLSL builds a matrix column-major from a flat run of scalar/vector
// components — `mat2(vec4(...))` fills column 0 with (x,y) and column 1 with
// (z,w). glslpp passed the single vec4 straight into the matrix constructor, so
// it emitted `OpConstantComposite %mat2 %vec4` — ONE constituent where mat2 needs
// TWO v2 columns = invalid SPIR-V (spirv-val: "Constituent count does not match
// matrix column count"), and the WGSL came out as `mat2x2f(vec4f(...))` which
// naga rejects ("cannot cast a vec4 to a mat2x2"). A mat2 column is a vec2, so
// the broken `mat2x2f(vec4` shape must never appear.
test "wgsl: matrix from a single oversized vector fills columns, not a cast (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(vec4(1.0, 2.0, 3.0, 4.0));
        \\    o = vec4(m[0], m[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try assertNotContains(wgsl, "mat2x2f(vec4"); // a mat2 column is a vec2, never a vec4
    try nagaValidateOrSkip(wgsl, "mat2-from-vec4");
}

// #170: the same column-major fill must regroup a MIX of scalars and vectors that
// straddle column boundaries — `mat2(vec3, float)` provides (x,y) | (z, f). The
// generic path passed the vec3 and the float as two constituents (vec3 is not a
// valid mat2 column = invalid SPIR-V).
test "wgsl: matrix from mixed scalar/vector args regroups into columns (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec3 a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(a, a.x);   // (a.x,a.y) | (a.z, a.x)
        \\    o = vec4(m[0], m[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "mat2-from-vec3-scalar");
}

// #170 regression guard: the already-working one-vector-per-column form
// (`mat2(vec2, vec2)`) must keep building the matrix straight from its column
// args — the new regroup branch must not disturb it.
test "wgsl: matrix from one vector per column is unchanged (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec2 a;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(a, a.yx);
        \\    o = vec4(m[0], m[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "mat2-from-two-vec2");
}

// #170: GLSL `==` / `!=` on an AGGREGATE (struct, array, matrix) compares
// structurally and returns a scalar bool. glslpp emitted OpIEqual/OpFOrdEqual
// directly on the struct/array/matrix operand — invalid SPIR-V (spirv-val:
// "Expected operands to be scalar or vector int/float") and naga-rejected WGSL
// ("Incompatible operands: Equal(Struct {...})"). Lower to a tree of per-leaf
// comparisons reduced with `&&`; the AND reduction (`&&`) must appear.
test "wgsl: struct equality lowers to per-member compares, not a struct == (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\struct S { float a; float b; };
        \\void main() {
        \\    S x = S(1.0, 2.0);
        \\    S y = S(1.0, 3.0);
        \\    o = (x == y) ? vec4(1.0) : vec4(0.0);
        \\}
    );
    defer alloc.free(wgsl);
    try assertContains(wgsl, "&&"); // AND-reduced per-member compares, not a struct ==
    try nagaValidateOrSkip(wgsl, "struct-equality");
}

// #170: array `==` is the same class — per-element compare + AND-reduce.
test "wgsl: array equality lowers to per-element compares (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float a[3] = float[](1.0, 2.0, 3.0);
        \\    float b[3] = float[](1.0, 2.0, 4.0);
        \\    o = (a == b) ? vec4(1.0) : vec4(0.0);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "array-equality");
}

// #170: `!=` is the logical negation of structural `==`, and the recursion must
// descend through a VECTOR member (vec2 → componentwise compare + all()).
test "wgsl: struct inequality with a vector member negates the equality (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec2 t;
        \\layout(location = 0) out vec4 o;
        \\struct S { vec2 p; float c; };
        \\void main() {
        \\    S x = S(t, 2.0);
        \\    S y = S(vec2(1.0), 3.0);
        \\    o = (x != y) ? vec4(1.0) : vec4(0.0);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "struct-inequality-vec-member");
}

// #170: the lowering recurses through ARBITRARY nesting — a struct holding
// another struct (with a vector) and an array must compare every leaf.
test "wgsl: nested struct/array equality recurses to every leaf (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec2 t;
        \\layout(location = 0) out vec4 o;
        \\struct Inner { vec2 p; };
        \\struct Outer { Inner i; float arr[2]; };
        \\void main() {
        \\    Outer x = Outer(Inner(t), float[](1.0, 2.0));
        \\    Outer y = Outer(Inner(vec2(1.0)), float[](1.0, 3.0));
        \\    o = (x == y) ? vec4(1.0) : vec4(0.0);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "nested-struct-array-equality");
}

// #170: matrices compare componentwise too (mat == mat was OpFOrdEqual on a
// matrix = invalid SPIR-V). Lower per-column (each column a vec compare + all).
test "wgsl: matrix equality lowers per-column, not a matrix == (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 a = mat2(t);
        \\    mat2 b = mat2(1.0);
        \\    o = (a == b) ? vec4(1.0) : vec4(0.0);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "matrix-equality");
}

// #170: GLSL implicitly converts the RHS to the lvalue type at a MULTI-component
// swizzle write — `v.xy = ivec2(...)` converts the ivec2 to vec2 before storing.
// glslpp fed the unconverted ivec2 straight into the OpVectorShuffle that merges
// it with the float vector `v`, mixing int and float components = invalid SPIR-V
// (spirv-val: "The Component Type of Vector 2 must be the same as ResultType") and
// naga-rejected WGSL. The single-component path (`v.x = intVar`) already converted;
// the multi-component path did not.
test "wgsl: multi-component swizzle write converts a cross-type RHS (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in ivec2 n;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(0.0);
        \\    v.xy = n;        // ivec2 → vec2 implicit conversion before the shuffle
        \\    o = v;
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "swizzle-write-cross-type");
}

// #170: the same implicit conversion is needed at a multi-component swizzle
// COMPOUND assignment — `v.xy += ivec2(...)` converts the ivec2 to vec2 before
// the add. glslpp applied the float op (fadd) directly to the unconverted ivec2
// operand = invalid SPIR-V ("Expected arithmetic operands to be of Result Type").
// Sibling of the plain swizzle-write conversion fix.
test "wgsl: multi-component swizzle compound-assign converts a cross-type vector RHS (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in ivec2 n;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(1.0);
        \\    v.xy += n;       // ivec2 → vec2 before the add
        \\    o = v;
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "swizzle-compound-cross-type-vec");
}

// #170: scalar cross-type RHS to a swizzle compound-assign (`v.xy += intScalar`)
// splat-broadcasts to the swizzle width — the scalar must be converted to the
// element type first, else the splat builds a vec2 from int constituents
// (spirv-val: "Expected Constituents to be scalar ... of Result Type").
test "wgsl: multi-component swizzle compound-assign converts a cross-type scalar RHS (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int n;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 v = vec4(1.0);
        \\    v.xy += n;       // int → float, then splat to vec2
        \\    o = v;
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "swizzle-compound-cross-type-scalar");
}

// #170: a matrix `*=`/`/=` scalar scales every component. SPIR-V has
// OpMatrixTimesScalar but no whole-matrix OpFMul/OpFDiv, yet the compound-assign
// path emitted `.fmul`/`.fdiv` on the matrix operand = invalid SPIR-V ("Expected
// floating scalar or vector type"). `/=` additionally produced naga-rejected WGSL
// (a `mat2x2 / f32` expression). Lower via OpMatrixTimesScalar, with `/=` using
// the reciprocal (matching glslang's `mat * (1.0/s)`).
test "wgsl: matrix divide-assign by a scalar lowers via reciprocal scale (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(4.0);
        \\    m /= t;
        \\    o = vec4(m[0], m[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "matrix-div-assign-scalar");
}

test "wgsl: matrix multiply-assign by an int scalar converts then scales (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int n;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(1.0);
        \\    m *= n;          // int → float, then OpMatrixTimesScalar
        \\    o = vec4(m[0], m[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "matrix-mul-assign-int-scalar");
}

// #170: binary `mat / scalar` divides every component by the scalar, but SPIR-V
// has no matrix OpFDiv — glslpp emitted OpFDiv on the matrix operand = invalid
// SPIR-V ("Expected floating scalar or vector type") and naga-rejected WGSL
// (`mat2x2 / f32`). Lower as `mat * (1.0/scalar)` via OpMatrixTimesScalar (the
// binary analog of the `mat /= scalar` compound fix; glslang lowers it the same).
test "wgsl: binary matrix divided by a scalar lowers via reciprocal scale (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 b = mat2(4.0);
        \\    mat2 d = b / t;
        \\    o = vec4(d[0], d[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "binary-matrix-div-scalar");
}

test "wgsl: binary matrix divided by an int scalar converts then scales (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int n;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 b = mat2(8.0);
        \\    mat2 d = b / n;   // int → float reciprocal, then OpMatrixTimesScalar
        \\    o = vec4(d[0], d[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "binary-matrix-div-int-scalar");
}

// #170: component-wise `mat + scalar` / `mat - scalar` / `scalar - mat` / `scalar
// / mat` apply the scalar to every matrix component (valid GLSL), but SPIR-V has
// no matrix OpFAdd/OpFSub/OpFDiv with a scalar operand — glslpp emitted those on a
// (matrix, scalar) pair = invalid SPIR-V and naga-rejected WGSL. Splat the scalar
// into a matrix and reuse the column-wise matrix-matrix op. (`mat * scalar` and
// `mat / scalar` are the OpMatrixTimesScalar family, handled separately.)
test "wgsl: matrix plus a scalar splats and adds component-wise (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(2.0);
        \\    mat2 r = m + t;
        \\    o = vec4(r[0], r[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "matrix-plus-scalar");
}

test "wgsl: scalar minus a matrix splats and subtracts component-wise (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(2.0);
        \\    mat2 r = t - m;     // splat t into a matrix, then mat - mat
        \\    o = vec4(r[0], r[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "scalar-minus-matrix");
}

test "wgsl: scalar divided by a matrix splats and divides component-wise (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(2.0);
        \\    mat2 r = t / m;     // splat t, then mat / mat (column-wise OpFDiv)
        \\    o = vec4(r[0], r[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "scalar-div-matrix");
}

test "wgsl: matrix plus an int scalar converts then splats (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int n;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(2.0);
        \\    mat2 r = m + n;     // int → float, splat, column-wise add
        \\    o = vec4(r[0], r[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "matrix-plus-int-scalar");
}

// #170: compound `mat += scalar` / `mat -= scalar` apply the scalar to every
// component (valid GLSL), but SPIR-V has no matrix OpFAdd/OpFSub with a scalar
// operand — glslpp emitted those on a (matrix, scalar) pair = invalid SPIR-V and
// naga-rejected WGSL. The compound analog of the binary `mat ± scalar` splat:
// splat the scalar into a matrix and reuse the column-wise matrix-matrix add/sub.
test "wgsl: matrix plus-assign a scalar splats and adds component-wise (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(2.0);
        \\    m += t;
        \\    o = vec4(m[0], m[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "matrix-plus-assign-scalar");
}

test "wgsl: matrix minus-assign an int scalar converts then splats (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int n;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    mat2 m = mat2(2.0);
        \\    m -= n;          // int → float, splat, column-wise sub
        \\    o = vec4(m[0], m[1]);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "matrix-minus-assign-int-scalar");
}

// #170: a multi-component swizzle WRITE whose base is an addressable lvalue that
// is NOT a bare identifier (`a[i].yz = ...` on an array element, `s.v.xy = ...` on
// a struct member) is valid GLSL, but glslpp's plain swizzle-write path only
// handled bare-identifier bases — anything else fell through to a generic lvalue
// assignment that cannot address a multi-component swizzle (error.InvalidAssignment),
// wrongly rejecting valid GLSL. Take a pointer to the base vector via analyzeLValue
// and shuffle the new values in (the compound `a[i].yz += ...` form already worked).
test "wgsl: multi-component swizzle write on an array element is accepted (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec2 t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec3 a[2];
        \\    a[0] = vec3(t, 1.0);
        \\    a[1] = vec3(0.0);
        \\    a[0].yz = t;     // swizzle write on an array-element vector
        \\    o = vec4(a[0], a[1].x);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "swizzle-write-array-element");
}

test "wgsl: multi-component swizzle write on a struct member is accepted (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in vec2 t;
        \\layout(location = 0) out vec4 o;
        \\struct S { vec3 v; };
        \\void main() {
        \\    S s;
        \\    s.v = vec3(1.0);
        \\    s.v.xy = t;      // swizzle write on a struct-member vector
        \\    o = vec4(s.v, 1.0);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "swizzle-write-struct-member");
}

// #170: the GLSL comma operator `(a, b)` evaluates a then b and yields b's value.
// The semantic layer already handled `comma_op`, but the parser only parsed it in
// for-loop clauses — a parenthesized comma expression elsewhere
// (`float b = (a = t, a + 1.0);`) parsed only the first operand, so the `)` was
// never reached and the whole declaration broke (`b` never registered →
// UndeclaredIdentifier), wrongly rejecting valid GLSL. Parse a full comma
// expression inside parentheses.
test "wgsl: comma operator in an initializer yields the last operand (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float a = 1.0;
        \\    float b = (a = t, a + 1.0);   // b = t + 1.0
        \\    o = vec4(b);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "comma-operator-initializer");
}

// #170: a const-qualified integer global used as an array size (`const int N = 3;
// float a[N];`) is valid, common GLSL, but glslpp's array-size resolver only
// handled integer literals and gl_WorkGroupSize (and early-returned for any
// non-compute stage that has no local_size) — a const-global name failed with
// SemanticFailed, wrongly rejecting valid GLSL. Resolve the name to its const
// global and fold its initializer.
test "wgsl: a const-int global used as an array size is resolved (#170)" {
    // A dynamic index keeps the array materialized (constant indices fold it
    // away), so the resolved size `3` is observable in the emitted type.
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int i;
        \\layout(location = 0) out vec4 o;
        \\const int N = 3;
        \\void main() {
        \\    float a[N];
        \\    a[0] = 1.0;
        \\    a[1] = 2.0;
        \\    a[2] = 3.0;
        \\    o = vec4(a[i], a[(i + 1) % N], 0.0, 1.0);
        \\}
    );
    defer alloc.free(wgsl);
    try assertContains(wgsl, "array<f32, 3>"); // size resolved to 3
    try nagaValidateOrSkip(wgsl, "const-global-array-size");
}

// #170: a constant arithmetic expression as an array size (`const int N = 3;
// float a[N + 1];`) is valid GLSL. The array-size resolver folded literals and
// bare const-global names, but not arithmetic — the parser stores such a
// dimension as source text, so resolving it needs re-parsing the text and
// folding the const expression. `a[N + 1]` failed (SemanticFailed); now it
// resolves to 4.
test "wgsl: a constant arithmetic expression as an array size is resolved (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int i;
        \\layout(location = 0) out vec4 o;
        \\const int N = 3;
        \\void main() {
        \\    float a[N + 1];          // size 4
        \\    a[0] = 1.0;
        \\    a[1] = 2.0;
        \\    a[2] = 3.0;
        \\    a[3] = 4.0;
        \\    o = vec4(a[i], a[(i + 1) % (N + 1)], 0.0, 1.0);
        \\}
    );
    defer alloc.free(wgsl);
    try assertContains(wgsl, "array<f32, 4>"); // N + 1 resolved to 4
    try nagaValidateOrSkip(wgsl, "const-expr-array-size");
}

// #170: an array-size expression that STARTS with an integer literal (`a[2 * N]`)
// was mis-parsed: the parser's dimension scan took the int-literal fast-path on
// the leading `2`, set the size to 2, then choked on `*` — the declaration broke
// and a later use raised UndeclaredIdentifier (valid GLSL wrongly rejected). The
// fast-path now only fires for a pure `[literal]` (next token is `]`); a
// literal-led expression falls to the const-expression fold (here size 6).
test "wgsl: an array size expression starting with a literal is resolved (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) flat in int i;
        \\layout(location = 0) out vec4 o;
        \\const int N = 3;
        \\void main() {
        \\    float a[2 * N];          // size 6
        \\    a[0] = 1.0;
        \\    a[5] = 2.0;
        \\    o = vec4(a[i % (2 * N)], a[(i + 1) % (2 * N)], 0.0, 1.0);
        \\}
    );
    defer alloc.free(wgsl);
    try assertContains(wgsl, "array<f32, 6>"); // 2 * N resolved to 6, not mis-parsed as 2
    try nagaValidateOrSkip(wgsl, "literal-led-array-size");
}

// #170: the C preprocessor expands a function-like macro's arguments BEFORE
// substituting them, so a macro call used as an argument (`ADD(SQ(t), 1.0)`)
// expands the inner `SQ(t)` first. glslpp substituted argument tokens raw, so the
// nested `SQ(t)` was left unexpanded and reached the parser as a call to an
// undefined `SQ` (UndeclaredIdentifier) — valid GLSL wrongly rejected. A single
// (non-nested) function macro already worked.
test "wgsl: a function-like macro call used as a macro argument is expanded (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\#define SQ(x) ((x) * (x))
        \\#define ADD(a, b) ((a) + (b))
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float r = ADD(SQ(t), SQ(t + 1.0));   // both SQ(...) must expand first
        \\    o = vec4(r);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "nested-function-macro-arg");
}

// #170: an object-like macro whose body is itself a macro (`#define A B` /
// `#define B 5.0`, or `#define SQT SQ(2.0)`) must have its replacement RESCANNED
// for further macros — the C preprocessor re-expands the result. glslpp emitted
// the object-macro body raw, so `A` reached the parser as the undefined identifier
// `B` (and `SQT` as a call to undefined `SQ`), wrongly rejecting valid GLSL. Also,
// `#define H (W/2)` (a SPACE before the `(`) is an object macro whose body is
// `(W/2)`, not a function-like macro — it was misclassified as function-like (so a
// bare `H` was never expanded) because the parser keyed on the `(` token without
// checking adjacency. These macro-chain forms are extremely common.
test "wgsl: an object macro whose body is another macro is rescanned (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\#define A B
        \\#define B 5.0
        \\#define SQ(x) ((x) * (x))
        \\#define SQT SQ(2.0)
        \\#define W 800
        \\#define H (W / 2)
        \\#define AREA (W * H)
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float x = A;        // A -> B -> 5.0
        \\    float y = SQT;      // SQT -> SQ(2.0) -> ((2.0)*(2.0))
        \\    float z = float(AREA); // AREA -> (W*H) -> (800*(800/2))  (spaced-paren object macros)
        \\    o = vec4(x, y, z, 1.0);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "object-macro-rescan");
}

// #170: a function-like macro's replacement list must also be RESCANNED for
// further macros — `#define WRAP(z) ADD(z, 1.0)` expands to `ADD(t, 1.0)`, and
// that `ADD(...)` must then expand too. glslpp emitted the substituted body raw,
// so the body's `ADD` call reached the parser undefined, wrongly rejecting valid
// GLSL. (The object-macro body rescan and argument pre-expansion landed earlier;
// this completes the rescan for the function-macro body.)
test "wgsl: a function macro whose body calls another macro is rescanned (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\#define ADD(a, b) ((a) + (b))
        \\#define SQ(x) ((x) * (x))
        \\#define WRAP(z) ADD(SQ(z), 1.0)
        \\layout(location = 0) in float t;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float r = WRAP(t);   // -> ADD(SQ(t), 1.0) -> ((((t)*(t))) + (1.0))
        \\    o = vec4(r);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "function-macro-body-rescan");
}

// #170: an array fragment output (`layout(location=0) out vec4 col[2]` — MRT via
// an array) was emitted as `-> @location(0) array<vec4f, 2>`, which naga rejects
// ("array type cannot be used for entry point outputs") — a silent-wrong at exit 0.
// WGSL has no array stage IO (it would need per-element @location struct members,
// not yet reconstructed here), so honest-error instead of emitting naga-rejected
// WGSL — matching the existing array-input / array-member-output guards.
test "wgsl: an array fragment output honest-errors instead of emitting array IO (#170)" {
    const src =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 col[2];
        \\void main() { col[0] = vec4(uv, 0.0, 1.0); col[1] = vec4(1.0 - uv, 0.0, 1.0); }
    ;
    try std.testing.expectError(error.UnsupportedOp, compileToWgsl(src));
}

// #170: synthetic preprocessor tokens (## paste, __LINE__, __VERSION__, stringify)
// carry source offsets past the original source into the preprocessor's
// synthetic-text buffer, but the parser read token text by offset from the
// ORIGINAL source — so `CAT(p, os)` (## paste) reached the parser as the first
// bytes of the source ("#v…" from "#version"), and __LINE__ as a non-numeric
// int_literal. The parser now reads an extended source (original + synthetic
// buffer); the error-context threadlocals are stabilized so they don't dangle.
test "wgsl: the ## token-paste operator concatenates into a usable identifier (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\#define CAT(a, b) a ## b
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    float pos = 3.0;
        \\    float r = CAT(p, os);   // pasted identifier `pos`
        \\    o = vec4(r);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "token-paste");
}

test "wgsl: __LINE__ and __VERSION__ expand to usable integer literals (#170)" {
    const wgsl = try compileToWgsl(
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    int ln = __LINE__;
        \\    int ver = __VERSION__;
        \\    o = vec4(float(ln), float(ver), 0.0, 1.0);
        \\}
    );
    defer alloc.free(wgsl);
    try nagaValidateOrSkip(wgsl, "line-version-macros");
}
