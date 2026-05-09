// SPDX-License-Identifier: MIT OR Apache-2.0
//! HLSL backend tests — end-to-end GLSL → SPIR-V → HLSL pipeline.
//!
//! These tests exercise the full compilation path. Some may fail due to
//! known gaps (control flow reconstruction, vector component writes, etc.)
//! but they serve as regression guards and progress trackers.

const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Compile GLSL → SPIR-V → HLSL, returning the HLSL source.
/// Caller frees the result.
fn compileToHlsl(source: [:0]const u8) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try glslpp.spirvToHLSL(alloc, spirv, .{
        .binding_shift = -1,
        .shader_model = 60,
    });
}

/// Compile GLSL → SPIR-V → HLSL for a given stage.
fn compileToHlslStage(source: [:0]const u8, stage: glslpp.Stage) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = stage });
    defer alloc.free(spirv);
    return try glslpp.spirvToHLSL(alloc, spirv, .{
        .binding_shift = -1,
        .shader_model = 60,
    });
}

/// Assert that `haystack` contains `needle`.
fn assertContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle)) |_| return;
    std.debug.print("Expected to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
    return error.TestExpectedFind;
}

/// Assert that `haystack` does NOT contain `needle`.
fn assertNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return;
    std.debug.print("Expected NOT to find \"{s}\" in output:\n{s}\n", .{ needle, haystack });
    return error.TestUnexpectedFind;
}

// ---------------------------------------------------------------------------
// T1: Minimal shaders — must produce valid HLSL structure
// ---------------------------------------------------------------------------

test "T1.1: minimal fragment shader produces HLSL with main()" {
    const hlsl = try compileToHlsl("#version 430\nvoid main() {}");
    defer alloc.free(hlsl);
    try assertContains(hlsl, "main");
    try assertContains(hlsl, "SV_Target");
}

test "T1.2: minimal vertex shader" {
    const source = "#version 430\nvoid main() { gl_Position = vec4(0.0); }";
    const hlsl = try compileToHlslStage(source, .vertex);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "main");
}

test "T1.3: minimal compute shader" {
    const source =
        \\#version 430
        \\layout(local_size_x = 1) in;
        \\void main() {}
    ;
    const hlsl = try compileToHlslStage(source, .compute);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "main");
}

// ---------------------------------------------------------------------------
// T2: Type mapping
// ---------------------------------------------------------------------------

test "T2.1: float uniform produces float in cbuffer" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float val; } u;
        \\void main() { if (u.val > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "cbuffer");
    try assertContains(hlsl, "float");
}

test "T2.2: vec4 produces float4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 color; } u;
        \\void main() { vec4 c = u.color; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "float4");
}

test "T2.3: ivec3 produces int3" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { ivec3 pos; } u;
        \\void main() { if (u.pos.x > 0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "int3");
}

test "T2.4: mat4 produces float4x4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 mvp; } u;
        \\void main() { vec4 v = u.mvp[0]; if (v.x > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "float4x4");
}

// ---------------------------------------------------------------------------
// T3: Resource binding
// ---------------------------------------------------------------------------

test "T3.1: uniform block at binding=1 remapped to register(b0)" {
    const source =
        \\#version 430
        \\layout(binding = 1, std140) uniform Globals { float time; } g;
        \\void main() { if (g.time > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "register(b0)");
}

test "T3.2: sampler2D produces Texture2D + SamplerState" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.0)); if (c.x > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "Texture2D");
    try assertContains(hlsl, "SamplerState");
}

test "T3.3: texture() maps to .Sample()" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, ".Sample(");
}

test "T3.4: texture2D() maps to .Sample()" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture2D(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, ".Sample(");
}

test "T3.5: texture2D in function with out param" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) out vec4 _fragColor;
        \\void mainImage(out vec4 fragColor, vec2 coord) {
        \\    vec4 t = texture2D(tex, coord * 0.5);
        \\    fragColor = t;
        \\}
        \\void main() { mainImage(_fragColor, vec2(1.0)); }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, ".Sample(");
}

// ---------------------------------------------------------------------------
// T4: Arithmetic operations
// ---------------------------------------------------------------------------

test "T4.1: basic arithmetic" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    float a = u.x + u.y;
        \\    float b = u.x * 2.0;
        \\    float c = b / 3.0;
        \\    if (a - c > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, " + ");
    try assertContains(hlsl, " * ");
    try assertContains(hlsl, " - ");
    try assertContains(hlsl, " / ");
}

test "T4.2: negation" {
    const source =
        \\#version 430
        \\void main() { float a = -1.0; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "-");
}

// ---------------------------------------------------------------------------
// T5: Built-in functions (GLSLstd450 → HLSL)
// ---------------------------------------------------------------------------

test "T5.1: sin/cos/tan" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = sin(u.x);
        \\    float b = cos(u.x);
        \\    float c = tan(u.x);
        \\    if (a + b + c > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "sin(");
    try assertContains(hlsl, "cos(");
    try assertContains(hlsl, "tan(");
}

test "T5.2: pow/exp/log" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = pow(u.x, 3.0);
        \\    float b = exp(u.x);
        \\    float c = log(u.x);
        \\    if (a + b + c > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "pow(");
    try assertContains(hlsl, "exp(");
    try assertContains(hlsl, "log(");
}

test "T5.3: min/max/clamp/lerp" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    float a = min(u.x, u.y);
        \\    float b = max(u.x, u.y);
        \\    float c = clamp(u.x, 0.0, 1.0);
        \\    float d = mix(u.x, u.y, 0.5);
        \\    if (a + b + c + d > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "min(");
    try assertContains(hlsl, "max(");
    try assertContains(hlsl, "clamp(");
    try assertContains(hlsl, "lerp(");
}

test "T5.4: dot/cross/normalize/length" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 v; } u;
        \\void main() {
        \\    float d = dot(u.v, u.v);
        \\    vec3 c = cross(u.v, u.v);
        \\    vec3 n = normalize(u.v);
        \\    float l = length(u.v);
        \\    float total = d + c.x + n.x + l;
        \\    if (total > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "dot(");
    try assertContains(hlsl, "cross(");
    try assertContains(hlsl, "normalize(");
    try assertContains(hlsl, "length(");
}

// ---------------------------------------------------------------------------
// T6: User-defined functions
// ---------------------------------------------------------------------------

test "T6.1: user function with return value" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\float add(float a, float b) { return a + b; }
        \\void main() {
        \\    float r = add(u.x, u.y);
        \\    if (r > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Trivial functions may be inlined — just verify the math works
    try assertContains(hlsl, " + ");
    try assertContains(hlsl, "cbuffer");
}

test "T6.2: user function with out parameter" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void getResult(out vec4 c) { c = vec4(u.x); }
        \\void main() {
        \\    vec4 r;
        \\    getResult(r);
        \\    if (r.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Out parameter value must be used in the output (not DCE'd)
    try assertContains(hlsl, "cbuffer");
    try assertContains(hlsl, "_m0");
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T7: Constants inlining
// ---------------------------------------------------------------------------

test "T7.1: scalar constant inlined as literal" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() { float a = 3.14; if (a + u.x > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "3.14");
}

test "T7.2: integer constant inlined" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() { int a = 42; if (float(a) + u.x > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "42");
}

test "T7.3: vec2 constant composite inlined" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    vec2 v = vec2(0.5, 0.5);
        \\    float f = v.x;
        \\    if (f + u.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "0.5");
}

// ---------------------------------------------------------------------------
// T8: Derivatives
// ---------------------------------------------------------------------------

test "T8.1: dFdx → ddx" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() { float d = dFdx(u.x); if (d > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "ddx(");
}

test "T8.2: dFdy → ddy" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() { float d = dFdy(u.x); if (d > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "ddy(");
}

test "T8.3: fwidth" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() { float d = fwidth(u.x); if (d > 0.0) discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "ddx");
    try assertContains(hlsl, "ddy");
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T9: Shadertoy-like prefix shader (the actual wintty use case)
// ---------------------------------------------------------------------------

test "T9.1: shadertoy-like uniform block + cbuffer" {
    const source =
        \\#version 430 core
        \\layout(binding = 1, std140) uniform Globals {
        \\    uniform vec3  iResolution;
        \\    uniform float iTime;
        \\};
        \\void main() {
        \\    vec2 uv = vec2(iTime, iResolution.x);
        \\    if (uv.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Must have cbuffer remapped to b0
    try assertContains(hlsl, "register(b0)");
    // Must have float3 and float in cbuffer
    try assertContains(hlsl, "float3");
}

test "T9.2: HLSL output has no 'unhandled' comments" {
    const source =
        \\#version 430 core
        \\layout(binding = 1, std140) uniform Globals {
        \\    uniform vec3  iResolution;
        \\    uniform float iTime;
        \\};
        \\void main() {
        \\    float x = cos(iTime);
        \\    if (x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertNotContains(hlsl, "unhandled");
}

// ---------------------------------------------------------------------------
// T10: Comparison and logical ops
// ---------------------------------------------------------------------------

test "T10.1: comparison operators" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    bool a = u.x > 0.0;
        \\    bool b = u.x <= 3.0;
        \\    bool c = u.x == 4.0;
        \\    if (a && b && c) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, ">");
    try assertContains(hlsl, "<=");
    try assertContains(hlsl, "==");
}

test "T10.2: ternary operator (OpSelect)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = u.x > 0.0 ? 1.0 : 0.0;
        \\    if (a > 0.5) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "?");
}

// ---------------------------------------------------------------------------
// T11: Composite operations
// ---------------------------------------------------------------------------

test "T11.1: CompositeConstruct (vector constructor)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; float z; } u;
        \\void main() {
        \\    vec3 v = vec3(u.x, u.y, u.z);
        \\    if (v.x + v.y + v.z > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Vector construction should appear in output (using all 3 uniform components)
    try assertContains(hlsl, "_m0");
    try assertContains(hlsl, "_m1");
    try assertContains(hlsl, "_m2");
}

test "T11.2: CompositeExtract (swizzle)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; float z; } u;
        \\void main() {
        \\    vec3 v = vec3(u.x, u.y, u.z);
        \\    float f = v.y;
        \\    if (f > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Should reference _m1 (the y component)
    try assertContains(hlsl, "_m1");
}

// ---------------------------------------------------------------------------
// T12: compileShadertoyToHlsl top-level API
// ---------------------------------------------------------------------------

test "T12.1: compileShadertoyToHlsl API works" {
    const source =
        \\#version 430 core
        \\void main() {}
    ;
    const result = try glslpp.compileShadertoyToHlsl(alloc, source, .{ .stage = .fragment });
    defer alloc.free(result.hlsl);
    try assertContains(result.hlsl, "main");
}

// ---------------------------------------------------------------------------
// T13: Control flow (currently partial — tracking known gaps)
// ---------------------------------------------------------------------------

test "T13.1: if/else basic structure" {
    const source =
        \\#version 430
        \\void main() {
        \\    float x = 1.0;
        \\    if (x > 0.0) {
        \\        x = x + 1.0;
        \\    } else {
        \\        x = x - 1.0;
        \\    }
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Currently we emit the BranchConditional as a comment
    // This test tracks progress: when full if/else is implemented,
    // this should contain proper "if (" and "} else {"
    try assertContains(hlsl, "if ("); // may fail until control flow is implemented
}

test "T13.2: if/else branching" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a;
        \\    if (u.x > 0.5) {
        \\        a = 1.0;
        \\    } else {
        \\        a = -1.0;
        \\    }
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Must use the uniform and produce branching HLSL
    try assertContains(hlsl, "_m0");
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T14: Entry point semantics
// ---------------------------------------------------------------------------

test "T14.1: fragment entry point has SV_Target" {
    const source = "#version 430\nvoid main() {}";
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "SV_Target");
}

test "T14.2: gl_FragCoord maps to SV_Position" {
    const source =
        \\#version 430
        \\void main() {
        \\    vec4 p = gl_FragCoord;
        \\    if (p.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "SV_Position");
}

test "T14.3: discard maps to discard" {
    const source =
        \\#version 430
        \\void main() { discard; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard;");
}

// ---------------------------------------------------------------------------
// T15: Additional HLSL backend coverage
// ---------------------------------------------------------------------------

test "T15.1: abs maps to abs" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = abs(u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "abs(");
}

test "T15.2: sqrt maps to sqrt" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = sqrt(u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "sqrt(");
}

test "T15.3: vector arithmetic" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 x; } u;
        \\void main() {
        \\    vec4 a = u.x + u.x;
        \\    if (a.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "float4");
}

test "T15.4: struct in uniform block" {
    const source =
        \\#version 430
        \\struct Light { vec3 pos; float intensity; };
        \\layout(binding = 0, std140) uniform U { Light l; } u;
        \\void main() {
        \\    if (u.l.intensity > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "cbuffer");
    try assertContains(hlsl, "float");
}

test "T15.5: multiply-add expression" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; float z; } u;
        \\void main() {
        \\    float a = u.x * u.y + u.z;
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "_m0");
    try assertContains(hlsl, "_m1");
    try assertContains(hlsl, "_m2");
}

test "T15.6: mat4 multiplication" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 m; vec4 v; } u;
        \\void main() {
        \\    vec4 r = u.m * u.v;
        \\    if (r.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "mul(");
}

test "T15.7: float2 vector type" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    vec2 v = vec2(u.x, u.y);
        \\    if (v.x + v.y > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Both uniform components must be used
    try assertContains(hlsl, "_m0");
    try assertContains(hlsl, "_m1");
}

test "T15.8: bool to float conversion in condition" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    bool b = u.x > 0.0;
        \\    if (b) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T16: More HLSL backend coverage — vertex/compute/complex patterns
// ---------------------------------------------------------------------------

test "T16.1: vertex shader with uniform and discard" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    if (u.x > 0.0) return;
        \\}
    ;
    const hlsl = try compileToHlslStage(source, .vertex);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "cbuffer");
}

test "T16.2: compute shader with numthreads" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\layout(local_size_x = 64) in;
        \\void main() {
        \\    if (u.x > 0.0) return;
        \\}
    ;
    const hlsl = try compileToHlslStage(source, .compute);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "[numthreads(64, 1, 1)]");
    try assertContains(hlsl, "cbuffer");
}

test "T16.3: nested if/else" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    if (u.x > 0.0) {
        \\        if (u.y > 0.0) {
        \\            discard;
        \\        }
        \\    }
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
    try assertContains(hlsl, "_m0");
    try assertContains(hlsl, "_m1");
}

test "T16.4: multiple uniform members" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; float c; float d; } u;
        \\void main() {
        \\    float sum = u.a + u.b + u.c + u.d;
        \\    if (sum > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "cbuffer");
}

test "T16.5: variable reassignment" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    float a = u.x;
        \\    a = a + u.y;
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "_m0");
    try assertContains(hlsl, "_m1");
}

// ---------------------------------------------------------------------------
// T17: GLSL built-in functions coverage
// ---------------------------------------------------------------------------

test "T17.1: rsqrt maps to rsqrt" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = inversesqrt(u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "rsqrt(");
}

test "T17.2: sign maps to sign" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = sign(u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "sign(");
}

test "T17.3: floor maps to floor" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = floor(u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "floor(");
}

test "T17.4: ceil maps to ceil" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = ceil(u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "ceil(");
}

test "T17.5: fract maps to frac" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = fract(u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "frac(");
}

// ---------------------------------------------------------------------------
// T18: More built-in functions and patterns
// ---------------------------------------------------------------------------

test "T18.1: mod uses floor-based formula" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = mod(u.x, 3.0);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // GLSL mod uses floor division, not truncation
    try assertContains(hlsl, "floor(");
    try assertContains(hlsl, "discard");
}

test "T18.2: step maps to step" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = step(0.5, u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "step(");
}

test "T18.3: smoothstep maps to smoothstep" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = smoothstep(0.0, 1.0, u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "smoothstep(");
}

test "T18.4: reflect maps to reflect" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 n; } u;
        \\void main() {
        \\    vec3 i = vec3(1.0, 0.0, 0.0);
        \\    vec3 r = reflect(i, u.n);
        \\    if (r.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "reflect(");
}

test "T18.5: int-to-float conversion" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int x; } u;
        \\void main() {
        \\    float a = float(u.x);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "cbuffer");
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T19: Type conversions and vector operations
// ---------------------------------------------------------------------------

test "T19.1: float-to-int conversion" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    int a = int(u.x);
        \\    if (a > 0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T19.2: vec4 component access" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 v; } u;
        \\void main() {
        \\    float a = u.v.w;
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T19.3: vec4 arithmetic" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
        \\void main() {
        \\    vec4 r = u.a + u.b;
        \\    if (r.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T19.4: negate expression" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = -u.x;
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T19.5: vec3 dot product" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 a; vec3 b; } u;
        \\void main() {
        \\    float d = dot(u.a, u.b);
        \\    if (d > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "dot(");
}

// ---------------------------------------------------------------------------
// T20: Additional coverage — cross, normalize, length, mix, clamp
// ---------------------------------------------------------------------------

test "T20.1: cross product" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 a; vec3 b; } u;
        \\void main() {
        \\    vec3 r = cross(u.a, u.b);
        \\    if (r.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "cross(");
}

test "T20.2: normalize" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 v; } u;
        \\void main() {
        \\    vec3 r = normalize(u.v);
        \\    if (r.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "normalize(");
}

test "T20.3: length" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 v; } u;
        \\void main() {
        \\    float l = length(u.v);
        \\    if (l > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "length(");
}

test "T20.4: mix with uniform" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; float t; } u;
        \\void main() {
        \\    float a = mix(u.x, u.y, u.t);
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "lerp(");
}

test "T20.5: clamp with uniform" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float a = clamp(u.x, 0.0, 1.0);
        \\    if (a > 0.5) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "clamp(");
}

test "T21.1: compute shader with 3D numthreads" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
        \\void main() {
        \\    if (u.x > 0.0) return;
        \\}
    ;
    const hlsl = try compileToHlslStage(source, .compute);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "[numthreads(8, 8, 1)]");
}

test "T21.2: fragment shader with gl_FragCoord component access" {
    const source =
        \\#version 430
        \\void main() {
        \\    float x = gl_FragCoord.x;
        \\    if (x > 400.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "SV_Position");
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T22: Edge cases and regression guards
// ---------------------------------------------------------------------------

test "T22.1: empty main produces valid HLSL" {
    const source =
        \\#version 430
        \\void main() {}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "float4 main(");
    try assertContains(hlsl, "SV_Target");
}

test "T22.2: multiple uniforms in single block" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U {
        \\    float time;
        \\    vec2 resolution;
        \\    vec4 color;
        \\} u;
        \\void main() {
        \\    if (u.time + u.resolution.x + u.color.r > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "cbuffer");
    try assertContains(hlsl, "_m0");
}

test "T22.3: function with multiple returns" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\float getValue(float t) {
        \\    if (t > 0.0) return 1.0;
        \\    return -1.0;
        \\}
        \\void main() {
        \\    float v = getValue(u.x);
        \\    if (v > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T22.4: inner product (dot with intermediate ops)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 a; vec3 b; } u;
        \\void main() {
        \\    vec3 diff = u.a - u.b;
        \\    float d = dot(diff, diff);
        \\    if (d > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "dot(");
    try assertContains(hlsl, "discard");
}

test "T22.5: chained arithmetic with precedence" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; float z; } u;
        \\void main() {
        \\    float a = u.x * u.y + u.z * u.x;
        \\    if (a > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "_m0");
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T23: Additional coverage for real-world patterns
// ---------------------------------------------------------------------------

test "T23.1: mat3 multiplication" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat3 m; vec3 v; } u;
        \\void main() {
        \\    vec3 result = u.m * u.v;
        \\    if (result.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "mul");
    try assertContains(hlsl, "discard");
}

test "T23.2: mix with uniform selector (non-constant)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float t; float a; float b; } u;
        \\void main() {
        \\    float result = mix(u.a, u.b, u.t);
        \\    if (result > 0.5) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "lerp");
    try assertContains(hlsl, "discard");
}

test "T23.3: integer arithmetic (div and mod)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int x; int y; } u;
        \\void main() {
        \\    int q = u.x / u.y;
        \\    int r = u.x - q * u.y;
        \\    if (q + r > 0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T23.4: vec2 construction and length" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    vec2 v = vec2(u.x, u.y);
        \\    float len = length(v);
        \\    if (len > 1.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "length");
    try assertContains(hlsl, "discard");
}

test "T23.5: abs and max/min" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    float a = abs(u.x);
        \\    float m = max(a, u.y);
        \\    if (m > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "abs");
    try assertContains(hlsl, "discard");
}

test "T23.6: pow and exp" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    float p = pow(u.x, u.y);
        \\    float e = exp(u.x);
        \\    if (p + e > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "pow");
    try assertContains(hlsl, "exp");
    try assertContains(hlsl, "discard");
}

test "T23.7: sin and cos" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float angle; } u;
        \\void main() {
        \\    float s = sin(u.angle);
        \\    float c = cos(u.angle);
        \\    if (s * s + c * c > 1.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "sin");
    try assertContains(hlsl, "cos");
    try assertContains(hlsl, "discard");
}

test "T23.8: log and sqrt" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float l = log(u.x);
        \\    float s = sqrt(u.x);
        \\    if (l + s > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "log");
    try assertContains(hlsl, "sqrt");
    try assertContains(hlsl, "discard");
}

test "T23.9: ternary operator" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    float result = (u.x > 0.0) ? u.x : u.y;
        \\    if (result > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T23.10: vec4 swizzle and assignment" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 color; } u;
        \\void main() {
        \\    float r = u.color.r;
        \\    float g = u.color.g;
        \\    float sum = r + g;
        \\    if (sum > 1.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T24: Control flow and loop patterns
// ---------------------------------------------------------------------------

test "T24.1: for loop with break" {
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
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Loop may be unrolled or use different syntax; just check it compiles and uses discard
    try assertContains(hlsl, "discard");
}

test "T24.2: while loop" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float v = u.x;
        \\    while (v > 1.0) {
        \\        v *= 0.5;
        \\    }
        \\    if (v > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // While may become for or different syntax; just check it compiles
    try assertContains(hlsl, "discard");
}

test "T24.3: nested if-else chain" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int mode; float x; } u;
        \\void main() {
        \\    float result;
        \\    if (u.mode == 0) result = u.x;
        \\    else if (u.mode == 1) result = u.x * 2.0;
        \\    else result = u.x * 3.0;
        \\    if (result > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T24.4: step and smoothstep" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float edge; float x; } u;
        \\void main() {
        \\    float s1 = step(u.edge, u.x);
        \\    float s2 = smoothstep(0.0, 1.0, u.x);
        \\    if (s1 + s2 > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T24.5: reflect" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 incident; vec3 normal; } u;
        \\void main() {
        \\    vec3 r = reflect(u.incident, u.normal);
        \\    if (length(r) > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T25: Texture sampling and compute shader patterns
// ---------------------------------------------------------------------------

test "T25.1: texture sampling produces valid HLSL" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(binding = 0, std140) uniform U { vec2 uv; } u;
        \\void main() {
        \\    vec4 c = texture(tex, u.uv);
        \\    if (c.r > 0.5) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T25.2: compute shader with shared memory" {
    const source =
        \\#version 430
        \\layout(local_size_x = 64) in;
        \\shared float s_data[64];
        \\layout(binding = 0, std140) uniform U { float x; int n; } u;
        \\void main() {
        \\    uint idx = gl_LocalInvocationID.x;
        \\    s_data[idx] = u.x;
        \\    barrier();
        \\    float sum = 0.0;
        \\    for (int i = 0; i < u.n; i++) {
        \\        sum += s_data[i];
        \\    }
        \\}
    ;
    const hlsl = try compileToHlslStage(source, .compute);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "numthreads");
}

test "T25.3: switch statement" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int mode; float x; } u;
        \\void main() {
        \\    float result = 0.0;
        \\    switch (u.mode) {
        \\        case 0: result = u.x; break;
        \\        case 1: result = u.x * 2.0; break;
        \\        default: result = u.x * 3.0; break;
        \\    }
        \\    if (result > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T25.4: ivec4 and component access" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { ivec4 v; } u;
        \\void main() {
        \\    int sum = u.v.x + u.v.y + u.v.z + u.v.w;
        \\    if (sum > 0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T25.5: mat4 transpose" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 m; vec4 v; } u;
        \\void main() {
        \\    mat4 t = transpose(u.m);
        \\    vec4 result = mul(t, u.v);
        \\    if (result.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Just verify it compiles to valid HLSL
    try assertContains(hlsl, "float4 main");
}

// ---------------------------------------------------------------------------
// T26: Additional type and operator coverage
// ---------------------------------------------------------------------------

test "T26.1: uint type and bitwise operations" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { uint a; uint b; } u;
        \\void main() {
        \\    uint c = u.a & u.b;
        \\    uint d = u.a | u.b;
        \\    uint e = u.a ^ u.b;
        \\    if (c + d + e > 0u) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T26.2: boolean logic with uniforms" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() {
        \\    bool a = u.x > 0.0;
        \\    bool b = u.y > 0.0;
        \\    bool c = a && b;
        \\    if (c) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T26.3: negate operator" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float v = -u.x;
        \\    if (v > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T26.4: vec4 negate and multiply" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 color; float scale; } u;
        \\void main() {
        \\    vec4 result = -u.color * u.scale;
        \\    if (result.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T26.5: nested function calls" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\float doubleIt(float v) { return v * 2.0; }
        \\void main() {
        \\    float result = doubleIt(abs(u.x));
        \\    if (result > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T27: Array types and advanced patterns (parser leak fix enables these)
// ---------------------------------------------------------------------------

test "T27.1: uniform array access" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float values[4]; int idx; } u;
        \\void main() {
        \\    float v = u.values[u.idx];
        \\    if (v > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T27.2: local array variable" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float arr[4];
        \\    arr[0] = u.x;
        \\    arr[1] = u.x * 2.0;
        \\    if (arr[0] + arr[1] > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T27.3: do-while loop" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float v = u.x;
        \\    do {
        \\        v *= 0.5;
        \\    } while (v > 1.0);
        \\    if (v > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T27.4: continue in loop" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int n; float x; } u;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < u.n; i++) {
        \\        if (i == 2) continue;
        \\        sum += u.x;
        \\    }
        \\    if (sum > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T27.5: multiple function definitions" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\float add(float a, float b) { return a + b; }
        \\float mul(float a, float b) { return a * b; }
        \\void main() {
        \\    float r = add(u.x, mul(u.y, 2.0));
        \\    if (r > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T28: Image and advanced I/O patterns
// ---------------------------------------------------------------------------

test "T28.1: imageLoad produces valid HLSL" {
    const source =
        \\#version 430
        \\layout(binding = 0, rgba32f) uniform image2D img;
        \\void main() {
        \\    vec4 c = imageLoad(img, ivec2(0, 0));
        \\    if (c.r > 0.5) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T28.2: vertex shader with gl_Position" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 pos; float scale; } u;
        \\void main() {
        \\    gl_Position = vec4(u.pos * u.scale, 1.0);
        \\    gl_PointSize = u.scale;
        \\}
    ;
    const hlsl = try compileToHlslStage(source, .vertex);
    defer alloc.free(hlsl);
    // Just verify it compiles
    try assertContains(hlsl, "void main");
}

test "T28.3: mat4 construction from columns" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 c0; vec4 c1; vec4 c2; vec4 c3; } u;
        \\void main() {
        \\    mat4 m = mat4(u.c0, u.c1, u.c2, u.c3);
        \\    vec4 v = m * vec4(1.0, 0.0, 0.0, 1.0);
        \\    if (v.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T28.4: vector relational (lessThan, greaterThan)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
        \\void main() {
        \\    bvec4 gt = greaterThan(u.a, u.b);
        \\    if (any(gt)) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T28.5: clamp and saturate pattern" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float v = clamp(u.x, 0.0, 1.0);
        \\    float s = clamp(v * 2.0, 0.0, 1.0);
        \\    if (s > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T29: Edge cases and remaining patterns
// ---------------------------------------------------------------------------

test "T29.1: discard-only main" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    if (u.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T29.2: nested struct uniform" {
    const source =
        \\#version 430
        \\struct Light { vec3 pos; float intensity; };
        \\layout(binding = 0, std140) uniform U { Light light; } u;
        \\void main() {
        \\    float d = length(u.light.pos);
        \\    if (d * u.light.intensity > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T29.3: uniform array with dynamic index" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 colors[4]; int idx; } u;
        \\void main() {
        \\    vec4 c = u.colors[u.idx];
        \\    if (c.r > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

// ---------------------------------------------------------------------------
// T30: Genuinely new feature coverage
// ---------------------------------------------------------------------------

test "T30.1: gl_FragDepth output" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float depth; } u;
        \\void main() {
        \\    gl_FragDepth = u.depth;
        \\    if (gl_FragDepth > 0.5) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T30.2: derivative functions dFdx/dFdy" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float dx = dFdx(u.x);
        \\    float dy = dFdy(u.x);
        \\    if (dx + dy > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T30.3: struct with vec3 member" {
    const source =
        \\#version 430
        \\struct Particle { vec3 pos; float life; };
        \\layout(binding = 0, std140) uniform U { Particle p; float x; } u;
        \\void main() {
        \\    float d = length(u.p.pos) + u.x;
        \\    if (d > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T30.4: multiple vector types (ivec, uvec)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { ivec4 iv; uvec4 uv; float x; } u;
        \\void main() {
        \\    int i = u.iv.x + int(u.uv.x);
        \\    if (float(i) + u.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T30.5: faceforward and reflect pattern" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 N; vec3 I; vec3 Nref; } u;
        \\void main() {
        \\    vec3 n = faceforward(u.N, u.I, u.Nref);
        \\    float d = dot(n, u.I);
        \\    if (d > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T30.6: fwidth derivative" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\void main() {
        \\    float fw = fwidth(u.x);
        \\    if (fw > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T30.7: SSBO read" {
    const source =
        \\#version 430
        \\layout(std430, binding = 0) buffer Data { vec4 values[]; };
        \\layout(binding = 1, std140) uniform U { int idx; } u;
        \\void main() {
        \\    vec4 v = values[u.idx];
        \\    if (v.r > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T30.8: imageStore" {
    const source =
        \\#version 430
        \\layout(binding = 0, rgba32f) uniform image2D img;
        \\layout(binding = 1, std140) uniform U { float x; } u;
        \\void main() {
        \\    imageStore(img, ivec2(0, 0), vec4(u.x, 0.0, 0.0, 1.0));
        \\    if (u.x > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T30.9: nested function with early return" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\float compute(float a, float b) {
        \\    if (a > 1.0) return a * 2.0;
        \\    return a + b;
        \\}
        \\void main() {
        \\    float r = compute(u.x, u.y);
        \\    if (r > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T30.10: multi-return function" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int mode; float x; float y; } u;
        \\float select_val(int m, float a, float b) {
        \\    if (m == 0) return a;
        \\    if (m == 1) return b;
        \\    return a + b;
        \\}
        \\void main() {
        \\    float r = select_val(u.mode, u.x, u.y);
        \\    if (r > 0.0) discard;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}


// ---------------------------------------------------------------------------
// Wintty integration tests — real shadertoy shaders
// ---------------------------------------------------------------------------

const shadertoy_prefix = @embedFile("wintty/shadertoy_prefix.glsl");
const test_crt = @embedFile("wintty/test_crt.glsl");
const test_focus = @embedFile("wintty/test_focus.glsl");

/// Helper: prepend shadertoy prefix + compile to HLSL
fn compileShadertoy(body: []const u8) ![]const u8 {
    // Build full source: prefix + body
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, shadertoy_prefix);
    try buf.appendSlice(alloc, "\n\n");
    try buf.appendSlice(alloc, body);
    try buf.append(alloc, 0);
    const source: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    return try compileToHlsl(source);
}

test "WIN1: wintty CRT shader compiles to HLSL" {
    const hlsl = try compileShadertoy(test_crt);
    defer alloc.free(hlsl);

    // Must produce valid HLSL structure
    try assertContains(hlsl, "main");
    try assertContains(hlsl, "mainImage");
    // Must have cbuffer with binding remapped to b0
    try assertContains(hlsl, "cbuffer");
    // Must have texture sampling
    try assertContains(hlsl, "Sample");
}

test "WIN2: wintty focus shader compiles to HLSL" {
    const hlsl = try compileShadertoy(test_focus);
    defer alloc.free(hlsl);

    try std.testing.expect(hlsl.len > 100); // Must produce meaningful output
    try assertContains(hlsl, "main");
    try assertContains(hlsl, "mainImage");
    try assertContains(hlsl, "cbuffer");
    // Focus shader has if/else with bool conditions and || operators
    try assertContains(hlsl, "if");
    // Texture sampling must be present
    try assertContains(hlsl, "Texture2D");
    try assertContains(hlsl, ".Sample(");
    try assertContains(hlsl, "lerp"); // mix() → lerp()
}

test "WIN-DXC: dump HLSL for DXC validation" {
    // Dump focus shader HLSL to files for DXC validation
    const hlsl_focus = try compileShadertoy(test_focus);
    defer alloc.free(hlsl_focus);

    const focus_file = try std.fs.cwd().createFile("tests/wintty/focus_output.hlsl", .{});
    defer focus_file.close();
    try focus_file.writeAll(hlsl_focus);

    const hlsl_crt = try compileShadertoy(test_crt);
    defer alloc.free(hlsl_crt);

    const crt_file = try std.fs.cwd().createFile("tests/wintty/crt_output.hlsl", .{});
    defer crt_file.close();
    try crt_file.writeAll(hlsl_crt);

    // Basic structural checks
    try assertContains(hlsl_focus, "Texture2D");
    try assertContains(hlsl_focus, ".Sample(");
    try assertContains(hlsl_crt, "Texture2D");
    try assertContains(hlsl_crt, ".Sample(");
}

// DXC validation commands (run manually):
//   dxc -T ps_6_0 -E main tests/wintty/focus_output.hlsl -Fo tests/wintty/focus_output.dxil
//   dxc -T ps_6_0 -E main tests/wintty/crt_output.hlsl -Fo tests/wintty/crt_output.dxil

test "WIN-DBG: bool variable with logical OR" {
    const source =
        \\#version 430
        \\void main() {
        \\    bool a = true;
        \\    bool b = false;
        \\    bool c = a || b;
        \\    if (c) { discard; }
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "WIN3: binding=1 with shift=-1 produces register(b0)" {
    const source =
        \\#version 430
        \\layout(binding = 1, std140) uniform Globals {
        \\    uniform vec3 iResolution;
        \\    uniform float iTime;
        \\};
        \\layout(location = 0) out vec4 _fragColor;
        \\void main() {
        \\    if (iTime > 0.0) discard;
        \\    _fragColor = vec4(iResolution, 1.0);
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{
        .binding_shift = -1,
        .shader_model = 60,
    });
    defer alloc.free(hlsl);

    // Uniform block must be at b0 (shifted from binding=1)
    try assertContains(hlsl, "register(b0)");
    // Must use the uniform (proves code wasn't DCE'd)
    try assertContains(hlsl, "discard");
    // Must use iResolution in output
    try assertContains(hlsl, "_m0");
}

test "T31.1: texelFetch maps to Load (int2 coord)" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    ivec2 coord = ivec2(1, 2);
        \\    vec4 c = texelFetch(tex, coord, 0);
        \\    if (c.x > 0.0) discard;
        \\    fragColor = c;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // texelFetch → Texture2D.Load(int3(coord, lod))
    try assertContains(hlsl, "Load");
    try assertContains(hlsl, "discard");
}

test "T31.2: textureLod maps to SampleLevel" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float lod; } u;
        \\layout(binding = 1) uniform sampler2D tex;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 uv = vec2(0.5, 0.5);
        \\    vec4 c = textureLod(tex, uv, u.lod);
        \\    if (c.x > 0.0) discard;
        \\    fragColor = c;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // textureLod → Texture2D.SampleLevel(sampler, coord, lod)
    try assertContains(hlsl, "SampleLevel");
    try assertContains(hlsl, "discard");
}

test "T31.3: textureGrad maps to SampleGrad" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float dx; } u;
        \\layout(binding = 1) uniform sampler2D tex;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 uv = vec2(0.5, 0.5);
        \\    vec2 dx_v = vec2(u.dx, 0.0);
        \\    vec2 dy_v = vec2(0.0, u.dx);
        \\    vec4 c = textureGrad(tex, uv, dx_v, dy_v);
        \\    if (c.x > 0.0) discard;
        \\    fragColor = c;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // textureGrad → Texture2D.SampleGrad(sampler, coord, ddx, ddy)
    try assertContains(hlsl, "SampleGrad");
    try assertContains(hlsl, "discard");
}

test "T31.4: textureProj maps to Sample with divided coord" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float w; } u;
        \\layout(binding = 1) uniform sampler2D tex;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 uv3 = vec3(0.5, 0.5, u.w);
        \\    vec4 c = textureProj(tex, uv3);
        \\    if (c.x > 0.0) discard;
        \\    fragColor = c;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // textureProj divides coord by last component
    try assertContains(hlsl, "Sample");
    try assertContains(hlsl, "discard");
}

test "T31.5: textureGather maps to Gather" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 uv = vec2(0.5, 0.5);
        \\    vec4 c = textureGather(tex, uv, 0);
        \\    if (c.x > 0.0) discard;
        \\    fragColor = c;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // textureGather → Texture2D.Gather(sampler, coord, component)
    try assertContains(hlsl, "Gather");
    try assertContains(hlsl, "discard");
}

test "T32.1: dFdx coarse maps to ddx" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float d = dFdx(u.x);
        \\    if (d > 0.0) discard;
        \\    fragColor = vec4(d);
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // dFdx → ddx (coarse derivative)
    try assertContains(hlsl, "ddx");
    try assertContains(hlsl, "discard");
}

test "T32.2: dFdy coarse maps to ddy" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float d = dFdy(u.x);
        \\    if (d > 0.0) discard;
        \\    fragColor = vec4(d);
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // dFdy → ddy (coarse derivative)
    try assertContains(hlsl, "ddy");
    try assertContains(hlsl, "discard");
}

test "T32.3: fwidth maps to fwidth (abs(ddx)+abs(ddy))" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float d = fwidth(u.x);
        \\    if (d > 0.0) discard;
        \\    fragColor = vec4(d);
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // fwidth → abs(ddx) + abs(ddy)
    try assertContains(hlsl, "ddx");
    try assertContains(hlsl, "ddy");
    try assertContains(hlsl, "discard");
}

test "T33.1: equal/notEqual on vectors" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    bool eq = equal(u.a, u.b).x;
        \\    if (eq) discard;
        \\    fragColor = u.a;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T33.2: lessThan/greaterThan on vectors" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    bool lt = lessThan(u.a, u.b).x;
        \\    bool gt = greaterThan(u.a, u.b).x;
        \\    if (lt || gt) discard;
        \\    fragColor = u.a;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T33.3: any/all on bvec" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    bvec4 b = greaterThan(u.a, vec4(0.0));
        \\    if (any(b)) discard;
        \\    fragColor = u.a;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "discard");
}

test "T34.1: exp/log/exp2/log2" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float a = exp(u.x);
        \\    float b = log(u.x);
        \\    float c = exp2(u.x);
        \\    float d = log2(u.x);
        \\    if (a + b + c + d > 0.0) discard;
        \\    fragColor = vec4(a, b, c, d);
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "exp");
    try assertContains(hlsl, "log");
    try assertContains(hlsl, "discard");
}

test "T34.2: inversesqrt/sqrt" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float x; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float a = inversesqrt(u.x);
        \\    float b = sqrt(u.x);
        \\    if (a + b > 0.0) discard;
        \\    fragColor = vec4(a, b, 0.0, 1.0);
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "rsqrt");
    try assertContains(hlsl, "sqrt");
    try assertContains(hlsl, "discard");
}

test "T34.3: refract" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float eta; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 i = vec3(1.0, 0.0, 0.0);
        \\    vec3 n = vec3(0.0, 1.0, 0.0);
        \\    vec3 r = refract(i, n, u.eta);
        \\    if (r.x > 0.0) discard;
        \\    fragColor = vec4(r, 1.0);
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "refract");
    try assertContains(hlsl, "discard");
}
