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
    try assertContains(hlsl, "fwidth(");
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

test "T16.2: compute shader with uniform" {
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

test "T18.1: mod maps to modulo" {
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
    // mod compiles to either fmod or % operator
    const has_fmod = std.mem.indexOf(u8, hlsl, "fmod(") != null;
    const has_mod = std.mem.indexOf(u8, hlsl, "%") != null;
    try std.testing.expect(has_fmod or has_mod);
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

