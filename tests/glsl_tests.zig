// SPDX-License-Identifier: MIT OR Apache-2.0
//! GLSL backend tests — end-to-end GLSL → SPIR-V → GLSL pipeline.
//!
//! All tests use `discard` as a side effect to prevent DCE from stripping the code.
//! The input is GLSL 430, compiled to SPIR-V, then cross-compiled back to GLSL 430.

const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

fn compileToGlsl(source: [:0]const u8) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    return try glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 });
}

fn compileToGlslStage(source: [:0]const u8, stage: glslpp.Stage) ![]const u8 {
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = stage });
    defer alloc.free(spirv);
    return try glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 });
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
// T1: Minimal shaders
// ---------------------------------------------------------------------------

test "T1.1: minimal fragment shader" {
    const glsl = try compileToGlsl("#version 430\nvoid main() {}");
    defer alloc.free(glsl);
    try assertContains(glsl, "#version 430");
    try assertContains(glsl, "void main()");
}

test "T1.2: minimal vertex shader" {
    const source = "#version 430\nvoid main() { gl_Position = vec4(0.0); }";
    const glsl = try compileToGlslStage(source, .vertex);
    defer alloc.free(glsl);
    try assertContains(glsl, "void main()");
}

test "T1.3: minimal compute shader" {
    const source =
        \\#version 430
        \\layout(local_size_x = 1) in;
        \\void main() {}
    ;
    const glsl = try compileToGlslStage(source, .compute);
    defer alloc.free(glsl);
    try assertContains(glsl, "void main()");
}

// ---------------------------------------------------------------------------
// T2: Type mapping — all tests use if(...) discard to prevent DCE
// ---------------------------------------------------------------------------

test "T2.1: float type in uniform block" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float val; } u;
        \\void main() { if (u.val > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "float");
    try assertContains(glsl, "uniform");
}

test "T2.2: vec4 type" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 color; } u;
        \\void main() { if (u.color.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "vec4");
}

test "T2.3: ivec4 type" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { ivec4 data; } u;
        \\void main() { if (u.data.x > 0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "ivec4");
}

test "T2.4: uint type" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { uint flags; } u;
        \\void main() { if (u.flags > 0u) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "uint");
}

test "T2.5: mat4 type" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 mvp; } u;
        \\void main() { vec4 p = u.mvp * vec4(1.0); if (p.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "mat4");
}

test "T2.6: vec2 type" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec2 offset; } u;
        \\void main() { if (u.offset.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "vec2");
}

test "T2.7: vec3 type" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 pos; } u;
        \\void main() { if (u.pos.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "vec3");
}

test "T2.8: mat2 type" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat2 rot; } u;
        \\void main() { vec2 r = u.rot * vec2(1.0); if (r.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "mat2");
}

test "T2.9: mat3 type" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat3 m; } u;
        \\void main() { vec3 r = u.m * vec3(1.0); if (r.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "mat3");
}

// ---------------------------------------------------------------------------
// T3: Resource binding
// ---------------------------------------------------------------------------

test "T3.1: uniform block with binding" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float val; } u;
        \\void main() { if (u.val > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "layout(binding = 0, std140) uniform");
}

test "T3.2: sampler2D" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "uniform sampler2D");
}

test "T3.3: multiple uniform blocks" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U1 { float a; } u1;
        \\layout(binding = 1, std140) uniform U2 { float b; } u2;
        \\void main() { if (u1.a + u2.b > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "binding = 0");
    try assertContains(glsl, "binding = 1");
}

test "T3.4: struct with array member" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float arr[4]; } u;
        \\void main() { if (u.arr[0] > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "uniform");
}

// ---------------------------------------------------------------------------
// T4: Arithmetic operations
// ---------------------------------------------------------------------------

test "T4.1: addition" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { float c = u.a + u.b; if (c > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "+");
}

test "T4.2: subtraction" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { float c = u.a - u.b; if (c > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, " - ");
}

test "T4.3: multiplication" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { float c = u.a * u.b; if (c > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "*");
}

test "T4.4: division" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { float c = u.a / u.b; if (c > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "/");
}

test "T4.5: negation" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { float c = -u.a; if (c > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
}

test "T4.6: vector arithmetic" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
        \\void main() { vec4 c = u.a + u.b; if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "+");
}

test "T4.7: vector times scalar" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; float s; } u;
        \\void main() { vec4 c = u.a * u.s; if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "*");
}

test "T4.8: matrix times vector" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 mvp; vec4 pos; } u;
        \\void main() { vec4 c = u.mvp * u.pos; if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "*");
}

test "T4.9: modulo" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { float c = mod(u.a, 2.0); if (c > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "mod(");
}

// ---------------------------------------------------------------------------
// T5: Built-in functions (GLSLstd450)
// ---------------------------------------------------------------------------

test "T5.1: sin" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (sin(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "sin(");
}

test "T5.2: cos" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (cos(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "cos(");
}

test "T5.3: pow" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { if (pow(u.a, u.b) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "pow(");
}

test "T5.4: abs" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (abs(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "abs(");
}

test "T5.5: clamp" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (clamp(u.a, 0.0, 1.0) > 0.5) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "clamp(");
}

test "T5.6: mix" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; float t; } u;
        \\void main() { if (mix(u.a, u.b, u.t) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "mix(");
}

test "T5.7: fract" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (fract(u.a) > 0.5) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "fract(");
}

test "T5.8: sqrt" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (sqrt(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "sqrt(");
}

test "T5.9: inversesqrt (not rsqrt)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (inversesqrt(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "inversesqrt(");
    try assertNotContains(glsl, "rsqrt");
}

test "T5.10: exp" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (exp(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "exp(");
}

test "T5.11: log" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (log(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "log(");
}

test "T5.12: exp2" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (exp2(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "exp2(");
}

test "T5.13: log2" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (log2(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "log2(");
}

test "T5.14: min" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { if (min(u.a, u.b) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "min(");
}

test "T5.15: max" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { if (max(u.a, u.b) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "max(");
}

test "T5.16: step" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float edge; float x_val; } u;
        \\void main() { if (step(u.edge, u.x_val) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "step(");
}

test "T5.17: smoothstep" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; float t; } u;
        \\void main() { if (smoothstep(u.a, u.b, u.t) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "smoothstep(");
}

test "T5.18: sign" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (sign(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "sign(");
}

test "T5.19: floor" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { float f = floor(u.a); if (f > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "floor(");
}

test "T5.20: atan" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { float c = atan(u.a, u.b); if (c > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "atan(");
}

test "T5.21: radians" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float deg; } u;
        \\void main() { if (radians(u.deg) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "radians(");
}

test "T5.22: degrees" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float rad; } u;
        \\void main() { if (degrees(u.rad) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "degrees(");
}

test "T5.23: tan" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (tan(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "tan(");
}

// ---------------------------------------------------------------------------
// T6: User-defined functions
// ---------------------------------------------------------------------------

test "T6.1: function call" {
    const source =
        \\#version 430
        \\float add(float a, float b) { return a + b; }
        \\layout(binding = 0, std140) uniform U { float x; float y; } u;
        \\void main() { float c = add(u.x, u.y); if (c > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "void main()");
}

test "T6.2: out parameter" {
    const source =
        \\#version 430
        \\void getVal(out float x) { x = 1.0; }
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { float v; getVal(v); float w = v + u.a; if (w > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "void main()");
}

test "T6.3: nested function calls" {
    const source =
        \\#version 430
        \\float f1(float a) { return a * 2.0; }
        \\float f2(float b) { return f1(b) + 1.0; }
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { float c = f2(u.a); if (c > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "void main()");
}

// ---------------------------------------------------------------------------
// T7: Constants
// ---------------------------------------------------------------------------

test "T7.1: float constant" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { float c = 3.14; float d = c + u.a; if (d > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "3.");
}

test "T7.2: int constant" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { int c = 42; float d = float(c) + u.a; if (d > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "42");
}

// ---------------------------------------------------------------------------
// T8: Derivatives
// ---------------------------------------------------------------------------

test "T8.1: dFdx" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (dFdx(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "dFdx(");
}

test "T8.2: dFdy" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (dFdy(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "dFdy(");
}

test "T8.3: fwidth" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (fwidth(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "fwidth(");
}

// ---------------------------------------------------------------------------
// T9: Comparison and logical ops
// ---------------------------------------------------------------------------

test "T9.1: less than" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { bool c = u.a < u.b; if (c) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "<");
}

test "T9.2: greater than" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { bool c = u.a > u.b; if (c) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, ">");
}

test "T9.3: equal" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int a; int b; } u;
        \\void main() { bool c = u.a == u.b; if (c) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "==");
}

test "T9.4: not equal" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int a; int b; } u;
        \\void main() { bool c = u.a != u.b; if (c) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "!=");
}

test "T9.5: logical or" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { bool c = (u.a < 0.0) || (u.a > 1.0); if (c) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "||");
}

test "T9.6: logical and" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { bool c = (u.a >= 0.0) && (u.a <= 1.0); if (c) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "&&");
}

test "T9.7: less than or equal" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { bool c = u.a <= u.b; if (c) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "<=");
}

test "T9.8: greater than or equal" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\void main() { bool c = u.a >= u.b; if (c) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, ">=");
}

// ---------------------------------------------------------------------------
// T10: Composite operations
// ---------------------------------------------------------------------------

test "T10.1: vector component extract" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\void main() { float x = u.a.x; if (x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, ".x");
}

test "T10.2: vector shuffle .xy" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\void main() { vec2 c = u.a.xy; if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, ".x");
    try assertContains(glsl, ".y");
}

test "T10.3: vector shuffle .xyz" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\void main() { vec3 c = u.a.xyz; if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, ".x");
    try assertContains(glsl, ".z");
}

// ---------------------------------------------------------------------------
// T11: Texture sampling
// ---------------------------------------------------------------------------

test "T11.1: texture() implicit lod" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.5)); if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "texture(");
}

test "T11.2: textureLod() explicit lod" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = textureLod(tex, vec2(0.5), 0.0); if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "textureLod(");
}

test "T11.3: texelFetch" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texelFetch(tex, ivec2(0), 0); if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "texelFetch(");
}

// ---------------------------------------------------------------------------
// T12: Control flow
// ---------------------------------------------------------------------------

test "T12.1: if-else" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() {
        \\    float b;
        \\    if (u.a > 0.5) { b = 1.0; } else { b = 0.0; }
        \\    if (b > 0.0) discard;
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "if");
    try assertContains(glsl, "else");
}

test "T12.2: discard" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (u.a < 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "discard");
}

test "T12.3: if without else" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { float b = 1.0; if (u.a > 0.5) { b = 0.0; } if (b > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "if");
}

// ---------------------------------------------------------------------------
// T13: Type conversions
// ---------------------------------------------------------------------------

test "T13.1: int to float" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { int a; } u;
        \\void main() { float f = float(u.a); if (f > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "float(");
}

test "T13.2: float to int" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { int i = int(u.a); if (i > 0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "int(");
}

// ---------------------------------------------------------------------------
// T14: Fragment output
// ---------------------------------------------------------------------------

test "T14.1: has #version 430" {
    const glsl = try compileToGlsl("#version 430\nvoid main() {}");
    defer alloc.free(glsl);
    try assertContains(glsl, "#version 430");
}

// ---------------------------------------------------------------------------
// T15: GLSL-specific (not HLSL)
// ---------------------------------------------------------------------------

test "T15.1: vec4 not float4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\void main() { if (u.a.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertNotContains(glsl, "float4");
    try assertContains(glsl, "vec4");
}

test "T15.2: ivec4 not int4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { ivec4 a; } u;
        \\void main() { if (u.a.x > 0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertNotContains(glsl, "int4");
    try assertContains(glsl, "ivec4");
}

test "T15.3: mat4 not float4x4" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 m; } u;
        \\void main() { vec4 p = u.m * vec4(1.0); if (p.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertNotContains(glsl, "float4x4");
    try assertContains(glsl, "mat4");
}

test "T15.4: texture() not Sample()" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform sampler2D tex;
        \\void main() { vec4 c = texture(tex, vec2(0.0)); if (c.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "texture(");
    try assertNotContains(glsl, "Sample(");
}

test "T15.5: mix not lerp" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; float t; } u;
        \\void main() { if (mix(u.a, u.b, u.t) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "mix(");
    try assertNotContains(glsl, "lerp");
}

test "T15.6: fract present (not frac)" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (fract(u.a) > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "fract(");
    // Verify no HLSL-isms
    try assertNotContains(glsl, "cbuffer");
}

test "T15.7: uniform not cbuffer" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (u.a > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "uniform");
    try assertNotContains(glsl, "cbuffer");
}

test "T15.8: discard not clip" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() { if (u.a < 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "discard");
    try assertNotContains(glsl, "clip");
}

// ---------------------------------------------------------------------------
// T16: Select (ternary)
// ---------------------------------------------------------------------------

test "T16.1: ternary operator" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; bool c; } u;
        \\void main() { float v = u.c ? u.a : u.b; if (v > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "?");
}

// ---------------------------------------------------------------------------
// T17: Dot product and transpose
// ---------------------------------------------------------------------------

test "T17.1: dot product" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec3 a; vec3 b; } u;
        \\void main() { float d = dot(u.a, u.b); if (d > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "dot(");
}

test "T17.2: transpose" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { mat4 m; } u;
        \\void main() { mat4 t = transpose(u.m); vec4 p = t * vec4(1.0); if (p.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "transpose(");
}

// ---------------------------------------------------------------------------
// T18: gl_FragCoord
// ---------------------------------------------------------------------------

test "T18.1: gl_FragCoord accessible" {
    const source =
        \\#version 430
        \\void main() { vec2 uv = gl_FragCoord.xy; if (uv.x > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "gl_FragCoord");
}

// ---------------------------------------------------------------------------
// T19: Complex expressions
// ---------------------------------------------------------------------------

test "T19.1: nested arithmetic" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; float b; float c; } u;
        \\void main() { float d = (u.a + u.b) * u.c; if (d > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "+");
    try assertContains(glsl, "*");
}

test "T19.2: chained assignments" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\void main() {
        \\    float b = u.a * 2.0;
        \\    float c = b + 1.0;
        \\    float d = c * c;
        \\    if (d > 0.0) discard;
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "*");
    try assertContains(glsl, "+");
}

test "T19.3: swizzle chain" {
    const source =
        \\#version 430
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\void main() { float x = u.a.x; float y = u.a.y; if (x + y > 0.0) discard; }
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, ".x");
    try assertContains(glsl, ".y");
}

// === Subgroup operation tests (Issue #3) ===

test "subgroupAll compiles to GLSL with subgroupAll" {
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
    const glsl = try compileToGlslStage(source, .compute);
    defer alloc.free(glsl);
    try assertContains(glsl, "subgroupAll");
}

test "subgroupAny compiles to GLSL with subgroupAny" {
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
    const glsl = try compileToGlslStage(source, .compute);
    defer alloc.free(glsl);
    try assertContains(glsl, "subgroupAny");
}

// === Specialization constant tests (Issue #6) ===

test "specialization constant compiles to GLSL with layout constant_id" {
    const source =
        \\#version 450
        \\layout(constant_id = 0) const uint WORKGROUP_SIZE = 64;
        \\layout(constant_id = 1) const float SCALE = 1.0;
        \\layout(local_size_x = WORKGROUP_SIZE) in;
        \\layout(std430, binding = 0) buffer Data { float values[]; };
        \\void main() {
        \\    uint idx = gl_GlobalInvocationID.x;
        \\    values[idx] = values[idx] * SCALE;
        \\}
    ;
    const glsl = try compileToGlslStage(source, .compute);
    defer alloc.free(glsl);
    try assertContains(glsl, "constant_id");
}

// === GLSL cbuffer member access tests ===

test "GLSL_CB: uniform block member access uses instance.member format" {
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
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    // Must use instance.member format (e.g. Globals_1.Globals_m0) not bare Globals_m0
    try assertContains(glsl, "Globals_1.");
    // Must NOT use bare member name without instance prefix in function bodies
    try assertNotContains(glsl, "= Globals_m0;");
    try assertNotContains(glsl, "= Globals_m1;");
}

test "glsl: bitfieldReverse roundtrip" {
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
    const glsl_out = try glslpp.spirvToGLSL(alloc, spv, .{});
    defer alloc.free(glsl_out);
    try std.testing.expect(std.mem.indexOf(u8, glsl_out, "bitfieldReverse") != null);
}

test "glsl: bitCount roundtrip" {
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
    const glsl_out = try glslpp.spirvToGLSL(alloc, spv, .{});
    defer alloc.free(glsl_out);
    try std.testing.expect(std.mem.indexOf(u8, glsl_out, "bitCount") != null);
}


test "T20.1: GLSL textureSize (ImageQuerySizeLod)" {
    const source =
        \\#version 450
        \\uniform sampler2D tex;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    ivec2 s = textureSize(tex, 0);
        \\    fragColor = vec4(float(s.x), float(s.y), 0.0, 1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "textureSize");
    try assertNotContains(glsl, "unhandled");
}

test "T20.2: GLSL fma (std450 #50)" {
    const source =
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = fma(2.0, 3.0, 1.0);
        \\    fragColor = vec4(r);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertNotContains(glsl, "unhandled");
}

test "T20.3: GLSL imageStore (OpImageWrite)" {
    const source =
        \\#version 430
        \\layout(rgba8, binding = 0) uniform writeonly image2D img;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    imageStore(img, ivec2(0, 0), vec4(1.0));
        \\    fragColor = vec4(1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertNotContains(glsl, "unhandled");
}

test "T20.4: GLSL imageLoad (OpImageRead)" {
    const source =
        \\#version 430
        \\layout(rgba8, binding = 0) uniform readonly image2D img;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 c = imageLoad(img, ivec2(0, 0));
        \\    fragColor = c;
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertNotContains(glsl, "unhandled");
}

test "T20.5: GLSL shadow texture (sampler2DShadow)" {
    const source =
        \\#version 430
        \\uniform sampler2DShadow shadowMap;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float d = texture(shadowMap, vec3(0.5, 0.5, 0.0));
        \\    fragColor = vec4(d);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertNotContains(glsl, "unhandled");
}

test "T20.6: GLSL textureGather (ImageGather)" {
    const source =
        \\#version 450
        \\uniform sampler2D tex;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 g = textureGather(tex, vec2(0.5), 0);
        \\    fragColor = g;
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertNotContains(glsl, "unhandled");
}

// Regression tests for std450 opcode mapping bugs - appended to glsl_tests.zig
// These test that specific std450 opcodes emit the correct GLSL function names

test "T21.1: inverse() not matrixCompMult (std450 #34)" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform UBO { mat4 mvp; };
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    mat4 inv = inverse(mvp);
        \\    fragColor = inv[0];
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "inverse(");
    try assertNotContains(glsl, "matrixCompMult");
    try assertNotContains(glsl, "unhandled");
}

test "T21.2: frexp() not ldexp (std450 #52)" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform UBO { float x; };
        \\layout(location = 0) out float fragColor;
        \\void main() {
        \\    int e;
        \\    float f = frexp(x, e);
        \\    fragColor = f + float(e);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "frexp(");
    try assertNotContains(glsl, "ldexp");
    try assertNotContains(glsl, "unhandled");
}

test "T21.3: asinh/acosh/atanh (std450 #22-24)" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform UBO { float x; };
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    fragColor = vec4(asinh(x), acosh(x), atanh(x), 1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "asinh(");
    try assertContains(glsl, "acosh(");
    try assertContains(glsl, "atanh(");
    try assertNotContains(glsl, "unhandled");
}

test "T21.4: max() with correct std450 enum (FMax=38)" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform UBO { vec4 a; vec4 b; };
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    fragColor = max(a, b);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "max(");
    try assertNotContains(glsl, "unhandled");
}

test "T21.5: ldexp (std450 #53)" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform UBO { float x; int e; };
        \\layout(location = 0) out float fragColor;
        \\void main() {
        \\    fragColor = ldexp(x, e);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "ldexp(");
    try assertNotContains(glsl, "unhandled");
}

test "T21.6: sign(int) via SSign (std450 #7)" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform UBO { int x; };
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int s = sign(x);
        \\    fragColor = vec4(float(s));
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "sign(");
    try assertNotContains(glsl, "unhandled");
}


// Regression test for FrexpStruct/ModfStruct struct decomposition
test "T22.1: frexp() struct decomposition (not ResType)" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform UBO { float x; };
        \\layout(location = 0) out float fragColor;
        \\void main() {
        \\    int e;
        \\    float f = frexp(x, e);
        \\    fragColor = f + float(e);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "frexp(");
    try assertNotContains(glsl, "ResType");
    try assertNotContains(glsl, "unhandled");
}

test "T22.2: modf() struct decomposition (not ResType)" {
    const source =
        \\#version 450
        \\layout(binding = 0) uniform UBO { float x; };
        \\layout(location = 0) out float fragColor;
        \\void main() {
        \\    float whole;
        \\    float frac_part = modf(x, whole);
        \\    fragColor = frac_part + whole;
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "modf(");
    try assertNotContains(glsl, "ResType");
    try assertNotContains(glsl, "unhandled");
}

// ---------------------------------------------------------------------------
// T23: Continue block emission (for-loop increment)
// ---------------------------------------------------------------------------

test "T23.1: for-loop counter increment (continue block)" {
    const source =
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\layout(location = 0) uniform int N;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < N; i++) {
        \\        sum += float(i);
        \\    }
        \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    // The output must contain a while(true) loop with a break
    try assertContains(glsl, "while (true)");
    try assertContains(glsl, "break");
    // The loop counter must be incremented (continue block emitted)
    // The optimizer may fold constants, so check for the increment pattern
    try assertContains(glsl, "+ 1");
    // Must not have unhandled opcodes
    try assertNotContains(glsl, "unhandled");
}

test "T23.2: nested for-loops" {
    const source =
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\layout(location = 0) uniform int N;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < N; i++) {
        \\        for (int j = 0; j < N; j++) {
        \\            sum += float(i * j);
        \\        }
        \\    }
        \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    // Both counters must be incremented
    // Count the number of "while (true)" — should be 2 for nested loops
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, glsl, pos, "while (true)")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    if (count < 2) {
        std.debug.print("Expected 2 nested while(true) loops, found {d}\n{s}\n", .{ count, glsl });
        return error.TestExpectedFind;
    }
    try assertNotContains(glsl, "unhandled");
}

test "T23.3: while-loop with update in continue block" {
    const source =
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\layout(location = 0) uniform float limit;
        \\void main() {
        \\    float x = 0.5;
        \\    int n = 0;
        \\    while (x > limit && n < 10) {
        \\        x *= 0.7;
        \\        n++;
        \\    }
        \\    FragColor = vec4(x, float(n), 0.0, 1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    // x must be updated (continue block emitted)
    // Check that the while loop has assignments inside it
    try assertContains(glsl, "while (true)");
    try assertContains(glsl, "break");
    try assertNotContains(glsl, "unhandled");
}

test "T24.1: continue in for-loop" {
    const source =
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        if (i == 3) continue;
        \\        sum += float(i);
        \\    }
        \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "continue");
    try assertNotContains(glsl, "unhandled");
}

test "T24.2: break in for-loop" {
    const source =
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        if (i == 7) break;
        \\        sum += float(i);
        \\    }
        \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "break");
    try assertNotContains(glsl, "unhandled");
}

test "T24.3: continue and break in for-loop" {
    const source =
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        if (i == 3) continue;
        \\        if (i == 7) break;
        \\        sum += float(i);
        \\    }
        \\    FragColor = vec4(sum, 0.0, 0.0, 1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "continue");
    try assertContains(glsl, "break");
    try assertNotContains(glsl, "unhandled");
}

test "T25.1: OpSelect with bvec4 condition (mix not ternary)" {
    const source =
        \\#version 430
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    bool b = gl_FragCoord.x > 128.0;
        \\    bvec4 cond = bvec4(b, b, b, b);
        \\    FragColor = mix(vec4(0.0), vec4(1.0), cond);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    // bvec4 in Select should emit mix() not ternary
    try assertContains(glsl, "mix(");
    try assertNotContains(glsl, "?");
    try assertNotContains(glsl, "unhandled");
}

test "GLSL: struct member access in CompositeExtract" {
    const source =
        \\#version 430
        \\struct Inner { float x; float y; };
        \\struct Outer { Inner a; float b; };
        \\layout(location = 0) out vec4 FragColor;
        \\layout(binding = 0, std140) uniform U { float u; } ubo;
        \\void main() {
        \\    Outer o;
        \\    o.a.x = ubo.u;
        \\    o.a.y = 2.0;
        \\    o.b = 3.0;
        \\    FragColor = vec4(o.a.x, o.a.y, o.b, 1.0);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    // Must use .memberName syntax for struct member access, not [index]
    try assertNotContains(glsl, "[0]");
    try assertNotContains(glsl, "[1]");
}

test "GLSL: isampler2D texture type detection" {
    const source =
        \\#version 430
        \\layout(binding = 0) uniform isampler2D tex;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    ivec4 v = texelFetch(tex, ivec2(0), 0);
        \\    FragColor = vec4(v);
        \\}
    ;
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "isampler2D");
    // The declaration should be 'isampler2D tex' not 'sampler2D tex' (but isampler contains sampler)
    // Check it's not preceded by a space (i.e., not bare sampler2D)
    try assertNotContains(glsl, " uniform sampler2D ");
}

test "GLSL: local array variable declaration" {
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
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    // Must emit float a[4] or similar array declaration
    try assertContains(glsl, "[4]");
}

test "GLSL: struct types used as local variables get declared" {
    // Uses frexp-modf.frag which has ResType/ResType_1 structs as local variables
    // that can't be optimized away by the SPIR-V optimizer
    const raw = @embedFile("spirv_cross_shaders/frexp-modf.frag");
    const source: [:0]const u8 = @ptrCast(raw);
    const glsl = try compileToGlsl(source);
    defer alloc.free(glsl);
    try assertContains(glsl, "struct ResType");
}

test "vertex shader declares input attributes and output varyings" {
    // Regression: the GLSL backend previously declared only the single fragment
    // color output, so vertex attributes (in) and varyings (out) were emitted as
    // undeclared identifiers — invalid GLSL (glslang rejects). They must now be
    // declared with their location qualifiers.
    const source =
        \\#version 450
        \\layout(location = 0) in vec3 in_pos;
        \\layout(location = 1) in vec3 in_normal;
        \\layout(location = 0) out vec3 v_normal;
        \\void main() {
        \\    v_normal = in_normal;
        \\    gl_Position = vec4(in_pos, 1.0);
        \\}
    ;
    const glsl = try compileToGlslStage(source, .vertex);
    defer alloc.free(glsl);
    try assertContains(glsl, "layout(location = 0) in vec3 in_pos;");
    try assertContains(glsl, "layout(location = 1) in vec3 in_normal;");
    try assertContains(glsl, "layout(location = 0) out vec3 v_normal;");
    // gl_Position is a predefined built-in — must NOT be declared as a varying.
    try assertContains(glsl, "gl_Position =");
}

test "fragment shader declares input varyings (not just the color output)" {
    // Regression: fragment input varyings were undeclared (only the output was).
    const source =
        \\#version 450
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = vec4(uv, 0.0, 1.0); }
    ;
    const glsl = try compileToGlslStage(source, .fragment);
    defer alloc.free(glsl);
    try assertContains(glsl, "layout(location = 0) in vec2 uv;");
    try assertContains(glsl, "layout(location = 0) out vec4 o;");
}

/// Strip OpSelectionMerge (247) / OpLoopMerge (246) instructions from a SPIR-V
/// word stream, producing an *unstructured* module (the kind external optimizers
/// or hand-authored SPIR-V can yield). Used to test that the backend fails loud
/// rather than emitting a lossy reconstruction.
fn stripMergeInstructions(a: std.mem.Allocator, spirv: []const u32) ![]u32 {
    var out = try std.ArrayList(u32).initCapacity(a, spirv.len);
    errdefer out.deinit(a);
    try out.appendSlice(a, spirv[0..5]); // header (magic, version, gen, bound, schema)
    var i: usize = 5;
    while (i < spirv.len) {
        const wc: usize = spirv[i] >> 16;
        const op: u32 = spirv[i] & 0xFFFF;
        if (wc == 0 or i + wc > spirv.len) break;
        if (op != 247 and op != 246) try out.appendSlice(a, spirv[i .. i + wc]);
        i += wc;
    }
    return out.toOwnedSlice(a);
}

test "GLSL: unstructured switch (stripped OpSelectionMerge) is recovered (G2)" {
    // Stripping OpSelectionMerge yields unstructured SPIR-V. Pre-G2 the backend
    // honest-errored (better than the original silent-wrong that dropped the
    // default case). With CFG structurization (G2) the merge is now RECOVERED and
    // the switch compiles FAITHFULLY — identical to the structured original, i.e.
    // the default case is preserved.
    const source =
        \\#version 450
        \\layout(location = 0) flat in int sel;
        \\layout(location = 0) out vec4 o;
        \\void main() {
        \\    vec4 c = vec4(0.0);
        \\    switch (sel) {
        \\        case 0: c = vec4(1.0); break;
        \\        case 1: c = vec4(0.5); break;
        \\        default: c = vec4(0.2); break;
        \\    }
        \\    o = c;
        \\}
    ;
    const spirv = try glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment });
    defer alloc.free(spirv);
    const ok = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 }); // structured original
    defer alloc.free(ok);
    const stripped = try stripMergeInstructions(alloc, spirv);
    defer alloc.free(stripped);
    const recovered = try glslpp.spirvToGLSL(alloc, stripped, .{ .version = 430 });
    defer alloc.free(recovered);
    try std.testing.expectEqualStrings(ok, recovered); // faithful recovery — default not dropped
}

// ---------------------------------------------------------------------------
// CFG structurization (G2) — end-to-end: strip a structured shader's merge
// instructions (making it unstructured), structurize it back, and confirm the
// backend produces the SAME GLSL as the original. Proves the recovery pass.
// ---------------------------------------------------------------------------

fn stripMergeInstrs(al: std.mem.Allocator, words: []const u32) ![]u32 {
    var out = std.ArrayList(u32).empty;
    errdefer out.deinit(al);
    try out.appendSlice(al, words[0..5]);
    var i: usize = 5;
    while (i < words.len) {
        const hw = words[i];
        const wc: usize = hw >> 16;
        const op: u16 = @truncate(hw & 0xFFFF);
        if (op != 246 and op != 247) try out.appendSlice(al, words[i .. i + wc]); // skip LoopMerge/SelectionMerge
        i += wc;
    }
    return out.toOwnedSlice(al);
}

test "G2: structurizeModule is a byte-identical no-op on already-structured SPIR-V" {
    const src =
        \\#version 450
        \\layout(location=0) in float t;
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    vec3 c = vec3(0.0);
        \\    if (t > 0.5) { c = vec3(1.0,0.0,0.0); } else { c = vec3(0.0,1.0,0.0); }
        \\    o = vec4(c, 1.0);
        \\}
    ;
    const spv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);
    const out = try glslpp.cfg_structurize.structurizeModule(alloc, spv);
    defer alloc.free(out);
    try std.testing.expectEqualSlices(u32, spv, out); // no-op: nothing to recover
}

test "G2: strip merges → structurize → backend GLSL matches the original" {
    const src =
        \\#version 450
        \\layout(location=0) in float t;
        \\layout(location=0) out vec4 o;
        \\void main() {
        \\    vec3 c = vec3(0.0);
        \\    if (t > 0.5) { c = vec3(1.0,0.0,0.0); } else { c = vec3(0.0,1.0,0.0); }
        \\    o = vec4(c, 1.0);
        \\}
    ;
    const spv = try glslpp.compileToSPIRVNoOpt(alloc, src, .{ .stage = .fragment });
    defer alloc.free(spv);

    // Ground truth: GLSL from the structured SPIR-V.
    const glsl_orig = try glslpp.spirvToGLSL(alloc, spv, .{ .version = 450 });
    defer alloc.free(glsl_orig);

    // Make it unstructured by stripping the merge instructions.
    const stripped = try stripMergeInstrs(alloc, spv);
    defer alloc.free(stripped);
    try std.testing.expect(stripped.len < spv.len); // something was removed

    // Recover structure, then cross-compile — must reproduce the original GLSL.
    const restructured = try glslpp.cfg_structurize.structurizeModule(alloc, stripped);
    defer alloc.free(restructured);
    const glsl_recovered = try glslpp.spirvToGLSL(alloc, restructured, .{ .version = 450 });
    defer alloc.free(glsl_recovered);

    try std.testing.expectEqualStrings(glsl_orig, glsl_recovered);
}

// NOTE: a LOOP strip-and-recover round-trip is intentionally absent — loop-merge
// recovery is not yet composed into structurizeModule (a loop's break-conditional
// is mis-handled by loop-unaware selection recovery; see cfg_structurize.zig).
// Unstructured loops keep honest-erroring (trustworthy interim). The loop-merge
// recovery + splice primitives are unit-tested in src/cfg_structurize.zig.

test "GLSL: sampler array (sampler2D tex[N]) declares + indexes correctly" {
    // Regression: a descriptor sampler array was mis-handled — the frontend put it
    // in Uniform storage (→ classified as a UBO) and the backend neither declared
    // it nor kept the element as a sampler. Now: `uniform sampler2D tex[4];` +
    // `texture(tex[2], uv)` (glslang-valid).
    const source =
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex[4];
        \\layout(location = 0) in vec2 uv;
        \\layout(location = 0) out vec4 o;
        \\void main() { o = texture(tex[2], uv); }
    ;
    const glsl = try compileToGlslStage(source, .fragment);
    defer alloc.free(glsl);
    try assertContains(glsl, "uniform sampler2D tex[4];");
    try assertContains(glsl, "texture(tex[2], uv)");
    try assertNotContains(glsl, "uniform tex"); // not mis-emitted as a UBO block
}

test "GLSL: module-scope const array indexed at runtime materializes its values" {
    // Regression (Design A): a `const T arr[N] = T[](...)` global indexed by a
    // runtime value lowered to a Private OpVariable with NO initializer and NO
    // stores — every backend read uninitialised memory (silent-wrong). Now the
    // frontend emits the folded OpConstantComposite as the variable's
    // initializer, and the backend aliases the variable to the promoted const
    // literal, so the values appear and the index resolves to them.
    const source =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) out float FragColor;
        \\const float LUT[4] = float[](1.0, 2.0, 3.0, 4.0);
        \\void main() {
        \\    int idx = int(gl_FragCoord.x) & 3;
        \\    FragColor = LUT[idx];
        \\}
    ;
    const glsl = try compileToGlslStage(source, .fragment);
    defer alloc.free(glsl);
    // The constant array is materialised with its values (not a bare uninit var).
    try assertContains(glsl, "const float ");
    try assertContains(glsl, "{1.0, 2.0, 3.0, 4.0}");
    // No undeclared `LUT` access leaks: the access must resolve to the const,
    // so the raw `LUT[` token must not appear in the body.
    try assertNotContains(glsl, "LUT[");
}

test "GLSL: integer fragment input is qualified flat" {
    // Regression: GLSL requires `flat` on integer/double fragment inputs
    // (glslang: "'int' : must be qualified as flat in"). The frontend preserves
    // the source qualifier as an OpDecorate Flat; the backend must emit it, else
    // the GLSL output is glslang-rejected (silent-wrong). `int(gl_FragCoord.x)`
    // avoids needing the input itself flat — the input here IS declared flat.
    const source =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) flat in int idx;
        \\layout(location = 0) out float FragColor;
        \\void main() { FragColor = float(idx); }
    ;
    const glsl = try compileToGlslStage(source, .fragment);
    defer alloc.free(glsl);
    try assertContains(glsl, "flat in int idx;");
    try assertNotContains(glsl, ") in int idx;"); // not the unqualified form
}

test "GLSL: multidimensional array local declares all dimensions" {
    // Regression: a 2D array local was declared with only ONE dimension
    // (`vec4 v[2];`) then assigned a `vec4 v[2][2]` const — glslang rejected the
    // type mismatch. The local-var array suffix must walk all nested TypeArray
    // dimensions (GLSL 4.30+ arrays of arrays), matching spirv-cross.
    const source =
        \\#version 310 es
        \\precision mediump float;
        \\layout(location = 0) flat in int index;
        \\layout(location = 0) out vec4 FragColor;
        \\void main() {
        \\    const vec4 foobars[2][2] = vec4[][](vec4[](vec4(1.0), vec4(2.0)), vec4[](vec4(8.0), vec4(10.0)));
        \\    FragColor = foobars[index][index + 1];
        \\}
    ;
    const glsl = try compileToGlslStage(source, .fragment);
    defer alloc.free(glsl);
    // Both the const declaration AND the local copy must carry both dimensions
    // (`[2][2]`). Before the fix, the local copy dropped a dimension, so the 2D
    // const couldn't be assigned to it. Two occurrences = const + local var.
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, glsl, i, "[2][2]")) |pos| : (i = pos + 1) count += 1;
    if (count < 2) {
        std.debug.print("Expected >=2 `[2][2]` (const + local), found {d}:\n{s}\n", .{ count, glsl });
        return error.TestExpectedFind;
    }
}

// ---------------------------------------------------------------------------
// Arrayed sampler type names (#187 part A).
//
// The OpTypeImage `Arrayed` operand (word[5]) was dropped when naming sampled
// textures, so `sampler2DArray`/`samplerCubeArray` degraded to the non-array
// `sampler2D`/`samplerCube`. GLSL keeps the array layer inside the sample
// coordinate, so ONLY the declared type name was wrong (the `texture(...)` call
// is unchanged). Oracle: spirv-cross --version 450.
//
// NOTE: GLSL drops the `Shadow` qualifier entirely (sampler2DArrayShadow →
// sampler2D) — a separate, pre-existing depth-naming bug that is OUT OF SCOPE
// here, so only the NON-shadow array types are pinned.
// ---------------------------------------------------------------------------

test "arrayed: sampler2DArray keeps the Array suffix" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2DArray tex;
        \\layout(location=0) in vec3 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = texture(tex, uv); }
    ;
    const glsl = try compileToGlslStage(source, .fragment);
    defer alloc.free(glsl);
    try assertContains(glsl, "sampler2DArray tex");
    // The sample call keeps the layer in the coord (no GLSL call change).
    try assertContains(glsl, "texture(tex, uv)");
}

test "arrayed: samplerCubeArray keeps the Array suffix" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform samplerCubeArray tex;
        \\layout(location=0) in vec4 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = texture(tex, uv); }
    ;
    const glsl = try compileToGlslStage(source, .fragment);
    defer alloc.free(glsl);
    try assertContains(glsl, "samplerCubeArray tex");
    // Must not degrade to the non-array name.
    try assertNotContains(glsl, "samplerCube tex;");
}

test "arrayed: plain sampler2D keeps no Array suffix (no regression)" {
    const source =
        \\#version 450
        \\layout(binding=0) uniform sampler2D tex;
        \\layout(location=0) in vec2 uv;
        \\layout(location=0) out vec4 o;
        \\void main(){ o = texture(tex, uv); }
    ;
    const glsl = try compileToGlslStage(source, .fragment);
    defer alloc.free(glsl);
    try assertContains(glsl, "sampler2D tex");
    try assertNotContains(glsl, "sampler2DArray");
}

// #260: atomicCompSwap(mem, compare, data) → GLSL atomicCompSwap(mem, compare, data).
// OpAtomicCompareExchange has TWO memory-semantics operands (Equal + Unequal), so its
// layout is [ptr][scope][eq-sem][uneq-sem][value(new/data)][comparator(compare)] —
// data at words[7], compare at words[8]. The backend read compare from words[7] (the
// data) and data from words[6] (the Unequal-semantics constant), so it emitted
// `atomicCompSwap(mem, 9u, 64u)` — compare=9 (the data), data=64 (a semantics const):
// silent-wrong. HLSL was the correct reference. (cross-backend sibling of #170.)
test "T-atomic.1: GLSL atomicCompSwap reads compare/data from correct operands (#260)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { uint lock; uint out_old; } b;
        \\void main() {
        \\    uint old = atomicCompSwap(b.lock, 7u, 9u); // compare 7, set 9
        \\    b.out_old = old;
        \\}
    ;
    const glsl = try compileToGlslStage(source, .compute);
    defer alloc.free(glsl);
    // Correct: atomicCompSwap(<ptr>, 7u, 9u) — compare 7, data 9.
    try assertContains(glsl, "atomicCompSwap(");
    try assertContains(glsl, ", 7u, 9u)");
    // The Unequal-semantics constant (0x40 == 64) must never appear as an argument.
    try assertNotContains(glsl, ", 9u, 64u)");
}

// #260: atomicExchange / atomicAdd must remain correct (they read value from words[6]).
test "T-atomic.2: GLSL atomicExchange/atomicAdd stay correct after compswap fix (#260)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(std430, binding = 0) buffer B { uint slot; uint total; uint out_old; } b;
        \\void main() {
        \\    uint old = atomicExchange(b.slot, 42u); // store 42
        \\    atomicAdd(b.total, 37u);                // add 37
        \\    b.out_old = old;
        \\}
    ;
    const glsl = try compileToGlslStage(source, .compute);
    defer alloc.free(glsl);
    try assertContains(glsl, "atomicExchange(");
    try assertContains(glsl, ", 42u)");
    try assertContains(glsl, "atomicAdd(");
    try assertContains(glsl, ", 37u)");
}

// #260: the IMAGE variant imageAtomicCompSwap(img, coord, compare, data) shares the
// same operand decode as the SSBO path. Guard the text output directly — conformance
// only validates the produced SPIR-V, not the emitted GLSL string.
test "T-atomic.3: GLSL imageAtomicCompSwap reads compare/data from correct operands (#260)" {
    const source =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\layout(r32ui, binding = 0) uniform uimage2D img;
        \\layout(std430, binding = 1) buffer B { uint out_old; } b;
        \\void main() {
        \\    b.out_old = imageAtomicCompSwap(img, ivec2(0), 5u, 3u); // compare 5, set 3
        \\}
    ;
    const glsl = try compileToGlslStage(source, .compute);
    defer alloc.free(glsl);
    try assertContains(glsl, "imageAtomicCompSwap(");
    try assertContains(glsl, ", 5u, 3u)");
    try assertNotContains(glsl, ", 3u, 64u)");
}

// GLSL.std.450 UMin(38)/UMax(41): unsigned min/max must lower to min()/max(), not the
// reverse. The backend's wrong F/S/U-grouping numbering swapped them (#272).
test "T-umm.1: GLSL unsigned+signed min/max are not swapped (#272)" {
    const min_src =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { uint ui; int si; } u;
        \\void main() { uint a = min(u.ui, 7u); int e = min(u.si, 3); o = vec4(float(a) + float(e), 0.0, 0.0, 1.0); }
    ;
    const m = try compileToGlslStage(min_src, .fragment);
    defer alloc.free(m);
    try assertContains(m, "min(");
    try assertNotContains(m, "max(");

    const max_src =
        \\#version 450
        \\layout(location = 0) out vec4 o;
        \\layout(binding = 0) uniform U { uint ui; int si; } u;
        \\void main() { uint b = max(u.ui, 9u); int f = max(u.si, 5); o = vec4(float(b) + float(f), 0.0, 0.0, 1.0); }
    ;
    const x = try compileToGlslStage(max_src, .fragment);
    defer alloc.free(x);
    try assertContains(x, "max(");
    try assertNotContains(x, "min(");
}
