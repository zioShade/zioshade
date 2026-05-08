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
        \\void getResult(out vec4 c) { c = vec4(1.0); }
        \\void main() {
        \\    vec4 r;
        \\    getResult(r);
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Function should appear before main
    const main_pos = std.mem.indexOf(u8, hlsl, "float4 main(").?;
    const func_pos = std.mem.indexOf(u8, hlsl, "getResult").?;
    try std.testing.expect(func_pos < main_pos);
}

// ---------------------------------------------------------------------------
// T7: Constants inlining
// ---------------------------------------------------------------------------

test "T7.1: scalar constant inlined as literal" {
    const source =
        \\#version 430
        \\void main() { float a = 3.14; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "3.14");
}

test "T7.2: integer constant inlined" {
    const source =
        \\#version 430
        \\void main() { int a = 42; }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "42");
}

test "T7.3: vec2 constant composite inlined" {
    const source =
        \\#version 430
        \\void main() {
        \\    vec2 v = vec2(0.5, 0.5);
        \\    float f = v.x;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "float2(0.5, 0.5)");
}

// ---------------------------------------------------------------------------
// T8: Derivatives
// ---------------------------------------------------------------------------

test "T8.1: dFdx → ddx" {
    const source =
        \\#version 430
        \\void main() { float d = dFdx(1.0); }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "ddx(");
}

test "T8.2: dFdy → ddy" {
    const source =
        \\#version 430
        \\void main() { float d = dFdy(1.0); }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "ddy(");
}

test "T8.3: fwidth" {
    const source =
        \\#version 430
        \\void main() { float d = fwidth(1.0); }
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "fwidth(");
}

// ---------------------------------------------------------------------------
// T9: Shadertoy-like prefix shader (the actual wintty use case)
// ---------------------------------------------------------------------------

test "T9.1: shadertoy prefix + simple mainImage" {
    const source =
        \\#version 430 core
        \\layout(binding = 1, std140) uniform Globals {
        \\    uniform vec3  iResolution;
        \\    uniform float iTime;
        \\};
        \\layout(binding = 0) uniform sampler2D iChannel0;
        \\layout(location = 0) in vec4 gl_FragCoord;
        \\layout(location = 0) out vec4 _fragColor;
        \\void mainImage( out vec4 fragColor, in vec2 fragCoord );
        \\void main() { mainImage (_fragColor, gl_FragCoord.xy); }
        \\
        \\void mainImage( out vec4 fragColor, in vec2 fragCoord )
        \\{
        \\    vec2 uv = fragCoord / iResolution.xy;
        \\    vec3 col = vec3(0.5) + 0.5 * cos(iTime + uv.xyx + vec3(0,2,4));
        \\    fragColor = vec4(col, 1.0);
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);

    // Must have cbuffer remapped to b0
    try assertContains(hlsl, "register(b0)");
    // Must have Texture2D + SamplerState
    try assertContains(hlsl, "Texture2D");
    try assertContains(hlsl, "SamplerState");
    // Must have mainImage function
    try assertContains(hlsl, "mainImage");
    // Must have main with SV_Target
    try assertContains(hlsl, "SV_Target");
    // Must use .Sample for texture access
    try assertContains(hlsl, ".Sample(");
    // Must have cos (used in the shader)
    try assertContains(hlsl, "cos(");
}

test "T9.2: shadertoy prefix produces no 'unhandled' comments" {
    const source =
        \\#version 430 core
        \\layout(binding = 1, std140) uniform Globals {
        \\    uniform vec3  iResolution;
        \\    uniform float iTime;
        \\};
        \\layout(binding = 0) uniform sampler2D iChannel0;
        \\layout(location = 0) in vec4 gl_FragCoord;
        \\layout(location = 0) out vec4 _fragColor;
        \\void mainImage( out vec4 fragColor, in vec2 fragCoord );
        \\void main() { mainImage (_fragColor, gl_FragCoord.xy); }
        \\
        \\void mainImage( out vec4 fragColor, in vec2 fragCoord )
        \\{
        \\    vec2 uv = fragCoord / iResolution.xy;
        \\    vec3 col = vec3(0.5) + 0.5 * cos(iTime + uv.xyx + vec3(0,2,4));
        \\    fragColor = vec4(col, 1.0);
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
        \\void main() {
        \\    bool a = 1.0 > 0.0;
        \\    bool b = 2.0 <= 3.0;
        \\    bool c = 4.0 == 4.0;
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
        \\void main() {
        \\    float a = true ? 1.0 : 0.0;
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
        \\void main() {
        \\    vec3 v = vec3(1.0, 2.0, 3.0);
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, "float3(");
}

test "T11.2: CompositeExtract (swizzle)" {
    const source =
        \\#version 430
        \\void main() {
        \\    vec3 v = vec3(1.0, 2.0, 3.0);
        \\    float f = v.y;
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    try assertContains(hlsl, ".y");
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

test "T13.2: for loop" {
    const source =
        \\#version 430
        \\void main() {
        \\    float sum = 0.0;
        \\    for (int i = 0; i < 10; i++) {
        \\        sum = sum + float(i);
        \\    }
        \\}
    ;
    const hlsl = try compileToHlsl(source);
    defer alloc.free(hlsl);
    // Currently loops are linearized; when loop reconstruction is done,
    // this should contain "for ("
    try assertContains(hlsl, "for ("); // may fail until loop reconstruction
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
        \\void main() { vec4 p = gl_FragCoord; }
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
