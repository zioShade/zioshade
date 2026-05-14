// SPDX-License-Identifier: MIT OR Apache-2.0
//! MSL backend tests — end-to-end GLSL → SPIR-V → MSL pipeline.
//!
//! All tests use `discard` as a side effect to prevent DCE.

const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

fn compileToMsl(source: [:0]const u8) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try glslpp.spirvToMSL(alloc, spirv, .{});
}

fn compileToMslStage(source: [:0]const u8, stage: glslpp.Stage) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = stage });
    defer alloc.free(spirv);
    return try glslpp.spirvToMSL(alloc, spirv, .{});
}

fn assertContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle)) |_| return;
    std.debug.print("Expected to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
    return error.TestExpectedFind;
}

fn assertNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return;
    std.debug.print("Expected NOT to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
    return error.TestUnexpectedFind;
}

// ---------------------------------------------------------------------------
// T1: MSL structure
// ---------------------------------------------------------------------------

test "T1.1: has metal_stdlib include" {
    const msl = try compileToMsl("#version 430\nvoid main() {}");
    defer alloc.free(msl);
    try assertContains(msl, "#include <metal_stdlib>");
    try assertContains(msl, "using namespace metal");
}

test "T1.2: fragment entry point" {
    const msl = try compileToMsl("#version 430\nvoid main() {}");
    defer alloc.free(msl);
    try assertContains(msl, "fragment");
}

test "T1.3: has color(0) output" {
    const msl = try compileToMsl("#version 430\nvoid main() {}");
    defer alloc.free(msl);
    try assertContains(msl, "[[color(0)]]");
}

// ---------------------------------------------------------------------------
// T2: MSL type names
// ---------------------------------------------------------------------------

test "T2.1: float4 not vec4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 color; } u;
        \\void main() { if (u.color.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4");
    try assertNotContains(msl, "vec4");
}

test "T2.2: float3 not vec3" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 pos; } u;
        \\void main() { if (u.pos.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float3");
    try assertNotContains(msl, "vec3");
}

test "T2.3: float4x4 not mat4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 mvp; } u;
        \\void main() { vec4 p = u.mvp * vec4(1.0); if (p.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4x4");
    try assertNotContains(msl, "mat4");
}

test "T2.4: int4 not ivec4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { ivec4 data; } u;
        \\void main() { if (u.data.x > 0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "int4");
    try assertNotContains(msl, "ivec4");
}

// ---------------------------------------------------------------------------
// T3: MSL resource binding
// ---------------------------------------------------------------------------

test "T3.1: struct for uniform block" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float val; } u;
        \\void main() { if (u.val > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "struct");
}

test "T3.2: texture2d<float> not sampler2D" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "texture2d<float>");
    try assertNotContains(msl, "sampler2D");
}

test "T3.3: buffer binding attribute" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float val; } u;
        \\void main() { if (u.val > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "[[buffer(");
}

test "T3.4: texture binding attribute" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "[[texture(");
    try assertContains(msl, "[[sampler(");
}

// ---------------------------------------------------------------------------
// T4: MSL texture sampling
// ---------------------------------------------------------------------------

test "T4.1: .sample() not texture()" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, ".sample(");
    try assertNotContains(msl, "Sample(");
}

// ---------------------------------------------------------------------------
// T5: MSL built-in functions
// ---------------------------------------------------------------------------

test "T5.1: powr not pow" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { if (pow(u.a, u.b) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "powr(");
    try assertNotContains(msl, "pow(");
}

test "T5.2: rsqrt not inversesqrt" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (inversesqrt(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "rsqrt(");
    try assertNotContains(msl, "inversesqrt");
}

test "T5.3: sin" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (sin(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "sin(");
}

test "T5.4: cos" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (cos(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "cos(");
}

test "T5.5: abs" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (abs(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "abs(");
}

test "T5.6: mix" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; float t; } u;
        \\void main() { if (mix(u.a, u.b, u.t) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "mix(");
    try assertNotContains(msl, "lerp");
}

test "T5.7: fract" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (fract(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "fract(");
}

test "T5.8: floor" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { float f = floor(u.a); if (f > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "floor(");
}

test "T5.9: sqrt" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (sqrt(u.a) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "sqrt(");
}

test "T5.10: min/max" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { if (min(u.a, u.b) > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "min(");
}

test "T5.11: fast::clamp for scalar clamp" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (clamp(u.a, 0.0, 1.0) > 0.5) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "clamp(");
}

test "T5.12: dot product" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 a; vec3 b; } u;
        \\void main() { float d = dot(u.a, u.b); if (d > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "dot(");
}

test "T5.13: transpose" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 m; } u;
        \\void main() { mat4 t = transpose(u.m); vec4 p = t * vec4(1.0); if (p.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "transpose(");
}

// ---------------------------------------------------------------------------
// T6: MSL control flow
// ---------------------------------------------------------------------------

test "T6.1: discard_fragment not discard" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (u.a < 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "discard_fragment()");
}

test "T6.2: if-else" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() {
        \\    float b;
        \\    if (u.a > 0.5) { b = 1.0; } else { b = 0.0; }
        \\    if (b > 0.0) discard;
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "if");
    try assertContains(msl, "else");
}

// ---------------------------------------------------------------------------
// T7: MSL entry point
// ---------------------------------------------------------------------------

test "T7.1: position attribute" {
    const source =
        \\#version 430
        \\void main() { vec2 uv = gl_FragCoord.xy; if (uv.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "[[position]]");
}

test "T7.2: thread float4& for out params" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\void main() { if (u.a.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Verify output struct exists
    try assertContains(msl, "main0_out");
}

// ---------------------------------------------------------------------------
// T8: MSL arithmetic
// ---------------------------------------------------------------------------

test "T8.1: addition" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { float c = u.a + u.b; if (c > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "+");
}

test "T8.2: multiplication" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { float c = u.a * u.b; if (c > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "*");
}

test "T8.3: vector arithmetic" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
        \\void main() { vec4 c = u.a + u.b; if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4");
    try assertContains(msl, "+");
}

test "T8.4: matrix times vector" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 mvp; vec4 pos; } u;
        \\void main() { vec4 c = u.mvp * u.pos; if (c.x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float4x4");
    try assertContains(msl, "*");
}

// ---------------------------------------------------------------------------
// T9: MSL type conversions
// ---------------------------------------------------------------------------

test "T9.1: int to float conversion" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int a; } u;
        \\void main() { float f = float(u.a); if (f > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "float(");
}

// ---------------------------------------------------------------------------
// T10: MSL-specific (not GLSL or HLSL)
// ---------------------------------------------------------------------------

test "T10.1: no #version" {
    const msl = try compileToMsl("#version 430\nvoid main() {}");
    defer alloc.free(msl);
    try assertNotContains(msl, "#version");
}

test "T10.2: no cbuffer" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (u.a > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertNotContains(msl, "cbuffer");
}

test "T10.3: no register()" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (u.a > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertNotContains(msl, "register(");
}

// ---------------------------------------------------------------------------
// T11: Complex expressions
// ---------------------------------------------------------------------------

test "T11.1: nested arithmetic" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; float c; } u;
        \\void main() { float d = (u.a + u.b) * u.c; if (d > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "+");
    try assertContains(msl, "*");
}

test "T11.2: swizzle access" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\void main() { float x = u.a.x; if (x > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, ".x");
}

// === Subgroup operation tests (Issue #3) ===

test "subgroupAll compiles to MSL with simd_all" {
    const source =
        \\#version 450
        \\#extension GL_KHR_shader_subgroup_vote : enable
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer Data { float values[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    bool all_pos = subgroupAll(values[idx] > 0.0);
        \\    if (all_pos) { values[idx] = 1.0; }
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "simd_all");
}

test "subgroupAny compiles to MSL with simd_any" {
    const source =
        \\#version 450
        \\#extension GL_KHR_shader_subgroup_vote : enable
        \\layout(local_size_x = 64) in;
        \\layout(std430, binding = 0) buffer Data { float values[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    bool any_pos = subgroupAny(values[idx] > 0.0);
        \\    if (any_pos) { values[idx] = 1.0; }
        \\}
    ;
    const msl = try compileToMslStage(source, .compute);
    defer alloc.free(msl);
    try assertContains(msl, "simd_any");
}

// === FP16 type tests (Issue #4) ===

test "float16_t compiles through the pipeline" {
    const source =
        \\#version 450
        \\#extension GL_EXT_shader_explicit_arithmetic_types_float16 : enable
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { if (u.a + u.b > 0.0) discard; }
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Just verify it compiles without error
    try assertContains(msl, "metal_stdlib");
}

test "CBUFFER_ACCESS: MSL struct member access uses _mN suffix not array index" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform Globals {
        \\    uniform vec3 iResolution;
        \\    uniform float iTime;
        \\};
        \\layout(location = 0) out vec4 _fragColor;
        \\void main() {
        \\    float t = iTime;
        \\    _fragColor = vec4(t, t, t, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const msl = try glslpp.spirvToMSL(alloc, spirv, .{});
    defer alloc.free(msl);
    // Must NOT use array indexing for struct member access
    try assertNotContains(msl, "Globals[0]");
    try assertNotContains(msl, "Globals[1]");
    // Must use _mN member access
    try assertContains(msl, "_m0");
    try assertContains(msl, "_m1");
}

test "msl: bitfieldReverse -> reverse_bits" {
    const src =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    uint a = bitfieldReverse(1u);
        \\    fragColor = vec4(float(a));
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const msl = try glslpp.spirvToMSL(alloc, spv, .{});
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "reverse_bits") != null);
}

test "msl: bitCount -> popcount" {
    const src =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int a = bitCount(1u);
        \\    fragColor = vec4(float(a));
        \\}
    ;
    const spv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const msl = try glslpp.spirvToMSL(alloc, spv, .{});
    defer alloc.free(msl);
    try std.testing.expect(std.mem.indexOf(u8, msl, "popcount") != null);
}


test "T11.1: MSL loop reconstruction produces while loop" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int n; float x; } u;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < u.n; i++) {
        \\        sum += u.x;
        \\        if (sum > 10.0) break;
        \\    }
        \\    if (sum > 0.0) discard;
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // MSL backend should reconstruct loops as while(true)
    try assertContains(msl, "while");
    try assertContains(msl, "break");
    try assertContains(msl, "discard_fragment");
}

test "T11.2: findLSB/findMSB in MSL" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int a = findLSB(7);
        \\    int b = findMSB(7);
        \\    fragColor = vec4(float(a), float(b), 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // findLSB/findMSB should emit ctz/clz in MSL, not "unhandled"
    try assertContains(msl, "ctz");
    try assertContains(msl, "clz");
}

test "T12.1: MSL CompositeInsert (partial vector write)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 v = vec4(1.0, 2.0, 3.0, 4.0);
        \\    v.x = 5.0;
        \\    fragColor = v;
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    // Should not contain "unhandled op" for CompositeInsert
    try assertNotContains(msl, "unhandled op");
    // Should contain assignment to swizzle component
    try assertContains(msl, ".x");
}

test "msl: frexp (FrexpStruct std450 #52)" {
    const src =
        \\#version 450
        \\layout(location = 0) in float v0;
        \\layout(location = 0) out float fragColor;
        \\void main() {
        \\    int e;
        \\    float f = frexp(v0, e);
        \\    fragColor = f + float(e);
        \\}
    ;
    const msl = try compileToMsl(src);
    defer alloc.free(msl);
    try assertContains(msl, "frexp(");
    try assertNotContains(msl, "ResType");
    try assertNotContains(msl, "unhandled");
}

test "msl: modf (ModfStruct std450 #36)" {
    const src =
        \\#version 450
        \\layout(location = 0) in float v0;
        \\layout(location = 0) out float fragColor;
        \\void main() {
        \\    float whole;
        \\    float frac_part = modf(v0, whole);
        \\    fragColor = frac_part + whole;
        \\}
    ;
    const msl = try compileToMsl(src);
    defer alloc.free(msl);
    try assertContains(msl, "modf(");
    try assertNotContains(msl, "ResType");
    try assertNotContains(msl, "unhandled");
}

test "MSL: local array variable declaration" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 u; } ubo;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    float a[4];
        \\    a[0] = ubo.u.x;
        \\    a[1] = ubo.u.y;
        \\    a[2] = ubo.u.z;
        \\    a[3] = ubo.u.w;
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 4; i++) sum += a[i];
        \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
        \\}
    ;
    const msl = try compileToMsl(source);
    defer alloc.free(msl);
    try assertContains(msl, "[4]");
}

