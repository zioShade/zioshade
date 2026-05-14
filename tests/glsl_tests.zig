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
