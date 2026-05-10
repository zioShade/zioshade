// SPDX-License-Identifier: MIT OR Apache-2.0
//! spirv-cross reference correctness tests.
//!
//! Uses GLSL shaders from the spirv-cross test suite (Apache-2.0) to validate
//! glslpp's compilation pipeline end-to-end. Each test:
//!   1. Reads a .frag shader from tests/spirv_cross_shaders/
//!   2. Compiles GLSL → SPIR-V
//!   3. Cross-compiles SPIR-V → HLSL, GLSL, MSL
//!   4. Validates: no crashes, no "unhandled" ops, output is non-empty
//!
//! spirv-cross is licensed under Apache-2.0.
//! See: https://github.com/KhronosGroup/SPIRV-Cross

const std = @import("std");
const glslpp = @import("glslpp");

const alloc = std.testing.allocator;

const ShaderTest = struct {
    name: [:0]const u8,
    source: [:0]const u8,
};

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

/// Compile a GLSL fragment shader through the full pipeline and validate all backends.
fn testShader(name: []const u8, source: [:0]const u8) !void {
    // Step 1: GLSL → SPIR-V
    const spirv = glslpp.compileToSPIRV(alloc, source, .{ .stage = .fragment }) catch |err| {
        std.debug.print("FAIL [{s}]: compileToSPIRV failed: {}\n", .{ name, err });
        return err;
    };
    defer alloc.free(spirv);

    // Step 2: SPIR-V → HLSL
    const hlsl = glslpp.spirvToHLSL(alloc, spirv, .{}) catch |err| {
        std.debug.print("FAIL [{s}]: spirvToHLSL failed: {}\n", .{ name, err });
        return err;
    };
    defer alloc.free(hlsl);

    // Step 3: SPIR-V → GLSL
    const glsl = glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 }) catch |err| {
        std.debug.print("FAIL [{s}]: spirvToGLSL failed: {}\n", .{ name, err });
        return err;
    };
    defer alloc.free(glsl);

    // Step 4: SPIR-V → MSL
    const msl = glslpp.spirvToMSL(alloc, spirv, .{}) catch |err| {
        std.debug.print("FAIL [{s}]: spirvToMSL failed: {}\n", .{ name, err });
        return err;
    };
    defer alloc.free(msl);

    // Validate HLSL
    try assertNotContains(hlsl, "unhandled");
    if (hlsl.len == 0) return error.EmptyHLSLOutput;

    // Validate GLSL
    try assertNotContains(glsl, "unhandled");
    if (glsl.len == 0) return error.EmptyGLSLOutput;

    // Validate MSL
    try assertNotContains(msl, "unhandled");
    if (msl.len == 0) return error.EmptyMSLOutput;
}

// ============================================================================
// Inline shader tests — hand-crafted patterns covering specific features.
// These are our own tests, not from spirv-cross.
// ============================================================================

test "R1.1: scalar float arithmetic (add/sub/mul/div)" {
    try testShader("R1.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = ((u.a + u.b) * u.a - u.b) / (u.a + 1.0);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R1.2: vector arithmetic" {
    try testShader("R1.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec4 a; vec4 b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 r = u.a + u.b * u.a;
        \\    fragColor = r;
        \\}
    );
}

test "R1.3: matrix multiply (mat4 * vec4)" {
    try testShader("R1.3",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { mat4 mvp; vec4 pos; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 r = u.mvp * u.pos;
        \\    fragColor = r;
        \\}
    );
}

test "R1.4: mat3 * vec3" {
    try testShader("R1.4",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { mat3 normal; vec3 v; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 r = u.normal * u.v;
        \\    fragColor = vec4(r, 1.0);
        \\}
    );
}

test "R1.5: mat2 * vec2" {
    try testShader("R1.5",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { mat2 rot; vec2 v; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 r = u.rot * u.v;
        \\    fragColor = vec4(r, 0.0, 1.0);
        \\}
    );
}

test "R2.1: vector swizzle .xyzw" {
    try testShader("R2.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 v = u.a.xyzw;
        \\    fragColor = v;
        \\}
    );
}

test "R2.2: vector swizzle .xzy" {
    try testShader("R2.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 v = u.a.xzy;
        \\    fragColor = vec4(v, 1.0);
        \\}
    );
}

test "R2.3: vector swizzle .xy" {
    try testShader("R2.3",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec4 a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 v = u.a.xy;
        \\    fragColor = vec4(v, 0.0, 1.0);
        \\}
    );
}

test "R3.1: all std450 trig (sin/cos/tan/asin/acos/atan)" {
    try testShader("R3.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = sin(u.a) + cos(u.a) + tan(u.a);
        \\    r += asin(u.a) + acos(u.a) + atan(u.a);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R3.2: hyperbolic trig (sinh/cosh/tanh)" {
    try testShader("R3.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = sinh(u.a) + cosh(u.a) + tanh(u.a);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R3.3: exp/log family" {
    try testShader("R3.3",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = exp(u.a) + log(u.a) + exp2(u.a) + log2(u.a);
        \\    r += pow(u.a, 2.0);
        \\    r += sqrt(u.a) + inversesqrt(u.a);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R3.4: common functions (abs/sign/floor/ceil/fract)" {
    try testShader("R3.4",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = abs(u.a) + sign(u.a);
        \\    r += floor(u.a) + ceil(u.a) + fract(u.a);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R3.5: min/max/clamp/mix/step/smoothstep" {
    try testShader("R3.5",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; float b; float c; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = min(u.a, u.b) + max(u.a, u.b);
        \\    r += clamp(u.a, 0.0, 1.0);
        \\    r += mix(u.a, u.b, u.c);
        \\    r += step(u.a, u.b);
        \\    r += smoothstep(0.0, 1.0, u.a);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R3.6: geometric functions (dot/cross/normalize/length/distance)" {
    try testShader("R3.6",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec3 a; vec3 b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float d = dot(u.a, u.b);
        \\    float l = length(u.a);
        \\    float dist = distance(u.a, u.b);
        \\    vec3 c = cross(u.a, u.b);
        \\    vec3 n = normalize(u.a);
        \\    fragColor = vec4(d + l + dist, c);
        \\}
    );
}

test "R3.7: transpose and determinant" {
    try testShader("R3.7",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { mat4 m; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    mat4 t = transpose(u.m);
        \\    float d = determinant(u.m);
        \\    fragColor = t[0] + vec4(d);
        \\}
    );
}

test "R3.8: atan2 (two-argument)" {
    try testShader("R3.8",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float y; float x; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = atan(u.y, u.x);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R3.9: radians/degrees" {
    try testShader("R3.9",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = radians(u.a) + degrees(u.a);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R4.1: texture sampling (sampler2D)" {
    try testShader("R4.1",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(binding = 0, std140) uniform U { vec2 uv; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 c = texture(tex, u.uv);
        \\    fragColor = c;
        \\}
    );
}

test "R4.2: texture with explicit LOD" {
    try testShader("R4.2",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(binding = 0, std140) uniform U { vec2 uv; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 c = textureLod(tex, u.uv, 0.0);
        \\    fragColor = c;
        \\}
    );
}

test "R4.3: texelFetch" {
    try testShader("R4.3",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(binding = 0, std140) uniform U { ivec2 coord; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 c = texelFetch(tex, u.coord, 0);
        \\    fragColor = c;
        \\}
    );
}

test "R4.4: multiple textures" {
    try testShader("R4.4",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex0;
        \\layout(binding = 1) uniform sampler2D tex1;
        \\layout(binding = 0, std140) uniform U { vec2 uv; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 a = texture(tex0, u.uv);
        \\    vec4 b = texture(tex1, u.uv);
        \\    fragColor = a + b;
        \\}
    );
}

test "R5.1: if-else control flow" {
    try testShader("R5.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r;
        \\    if (u.a > 0.5) {
        \\        r = 1.0;
        \\    } else {
        \\        r = 0.0;
        \\    }
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R5.2: nested if-else" {
    try testShader("R5.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r;
        \\    if (u.a > 0.5) {
        \\        if (u.b > 0.5) { r = 1.0; } else { r = 2.0; }
        \\    } else {
        \\        r = 0.0;
        \\    }
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R5.3: for loop" {
    try testShader("R5.3",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = 0.0;
        \\    for (int i = 0; i < 10; i++) { r += u.a; }
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R5.4: for loop with break" {
    try testShader("R5.4",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = 0.0;
        \\    for (int i = 0; i < 10; i++) { r += u.a; if (r > 5.0) break; }
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R5.5: for loop with continue" {
    try testShader("R5.5",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = 0.0;
        \\    for (int i = 0; i < 10; i++) { if (i == 5) continue; r += u.a; }
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R5.6: switch statement" {
    try testShader("R5.6",
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
    );
}

test "R6.1: user function with return" {
    try testShader("R6.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\float add(float x, float y) { return x + y; }
        \\void main() {
        \\    fragColor = vec4(add(u.a, u.b));
        \\}
    );
}

test "R6.2: user function calling another function" {
    try testShader("R6.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\float double_val(float x) { return x * 2.0; }
        \\float quad_val(float x) { return double_val(double_val(x)); }
        \\void main() {
        \\    fragColor = vec4(quad_val(u.a));
        \\}
    );
}

test "R6.3: function with out parameter" {
    try testShader("R6.3",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void foo(float x, out float y) { y = x * 2.0; }
        \\void main() {
        \\    float r;
        \\    foo(u.a, r);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R7.1: type conversion (int/float)" {
    try testShader("R7.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { int a; float b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float f = float(u.a);
        \\    int i = int(u.b);
        \\    fragColor = vec4(f + float(i));
        \\}
    );
}

test "R7.2: uint type" {
    try testShader("R7.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { uint a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float f = float(u.a);
        \\    fragColor = vec4(f);
        \\}
    );
}

test "R7.3: bool comparisons" {
    try testShader("R7.3",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    bool b1 = u.a < u.b;
        \\    bool b2 = u.a > u.b;
        \\    bool b3 = u.a == u.b;
        \\    bool b4 = u.a != u.b;
        \\    float r = 0.0;
        \\    if (b1) r += 1.0;
        \\    if (b2) r += 2.0;
        \\    if (b3) r += 3.0;
        \\    if (b4) r += 4.0;
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R7.4: ternary operator" {
    try testShader("R7.4",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = (u.a > 0.5) ? u.a : u.b;
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R8.1: derivatives (dFdx/dFdy/fwidth)" {
    try testShader("R8.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float dx = dFdx(u.a);
        \\    float dy = dFdy(u.a);
        \\    float fw = fwidth(u.a);
        \\    fragColor = vec4(dx + dy + fw);
        \\}
    );
}

test "R8.2: negation" {
    try testShader("R8.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; vec3 v; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float f = -u.a;
        \\    vec3 v = -u.v;
        \\    fragColor = vec4(f, v);
        \\}
    );
}

test "R8.3: modulo" {
    try testShader("R8.3",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    float r = mod(u.a, u.b);
        \\    fragColor = vec4(r);
        \\}
    );
}

test "R9.1: constant composite (vec3(1.0))" {
    try testShader("R9.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 ones = vec3(1.0);
        \\    fragColor = vec4(ones * u.a, 1.0);
        \\}
    );
}

test "R9.2: constant composite (vec4 splat)" {
    try testShader("R9.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 v = vec4(u.a);
        \\    fragColor = v;
        \\}
    );
}

test "R9.3: constant composite (vec4 with mixed args)" {
    try testShader("R9.3",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; float b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 v = vec4(u.a, u.b, 0.0, 1.0);
        \\    fragColor = v;
        \\}
    );
}

test "R10.1: struct uniform block" {
    try testShader("R10.1",
        \\#version 450
        \\struct Light {
        \\    vec3 position;
        \\    float intensity;
        \\    vec3 color;
        \\};
        \\layout(binding = 0, std140) uniform U { Light light; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 r = u.light.color * u.light.intensity;
        \\    fragColor = vec4(r, 1.0);
        \\}
    );
}

test "R10.2: array member in uniform block" {
    try testShader("R10.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec4 data[4]; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec4 r = u.data[0] + u.data[1] + u.data[2] + u.data[3];
        \\    fragColor = r;
        \\}
    );
}

test "R10.3: multiple uniform blocks" {
    try testShader("R10.3",
        \\#version 450
        \\layout(binding = 0, std140) uniform U1 { float a; } u1;
        \\layout(binding = 1, std140) uniform U2 { float b; } u2;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    fragColor = vec4(u1.a + u2.b);
        \\}
    );
}

test "R11.1: gl_FragCoord usage" {
    try testShader("R11.1",
        \\#version 450
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy;
        \\    fragColor = vec4(uv, 0.0, 1.0);
        \\}
    );
}

test "R11.2: discard" {
    try testShader("R11.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    if (u.a < 0.0) discard;
        \\    fragColor = vec4(1.0);
        \\}
    );
}

test "R12.1: bitwise ops on integers" {
    try testShader("R12.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { int a; int b; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int r = (u.a | u.b) & (u.a ^ u.b);
        \\    fragColor = vec4(float(r));
        \\}
    );
}

test "R12.2: shift operations" {
    try testShader("R12.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { int a; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    int r = u.a << 2;
        \\    r = r >> 1;
        \\    fragColor = vec4(float(r));
        \\}
    );
}

test "R13.1: vector times scalar" {
    try testShader("R13.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec3 v; float s; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 r = u.v * u.s;
        \\    fragColor = vec4(r, 1.0);
        \\}
    );
}

test "R13.2: matrix times scalar" {
    try testShader("R13.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { mat4 m; float s; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    mat4 r = u.m * u.s;
        \\    fragColor = r[0];
        \\}
    );
}

test "R14.1: complex expression (shadertoy-like)" {
    try testShader("R14.1",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { float time; vec2 resolution; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 uv = (gl_FragCoord.xy - 0.5 * u.resolution) / u.resolution.y;
        \\    float d = length(uv);
        \\    float a = atan(uv.y, uv.x);
        \\    float r = fract(d * 10.0 - u.time);
        \\    float c = smoothstep(0.0, 0.1, abs(r - 0.5));
        \\    vec3 col = vec3(0.5 + 0.5 * cos(a + time + vec3(0.0, 2.0, 4.0)));
        \\    fragColor = vec4(col * c, 1.0);
        \\}
    );
}

test "R14.2: lighting-like calculation" {
    try testShader("R14.2",
        \\#version 450
        \\layout(binding = 0, std140) uniform U { vec3 lightDir; vec3 viewDir; vec3 normal; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec3 N = normalize(u.normal);
        \\    vec3 L = normalize(u.lightDir);
        \\    vec3 V = normalize(u.viewDir);
        \\    vec3 H = normalize(L + V);
        \\    float diff = max(dot(N, L), 0.0);
        \\    float spec = pow(max(dot(N, H), 0.0), 32.0);
        \\    vec3 color = vec3(0.8) * diff + vec3(1.0) * spec;
        \\    fragColor = vec4(color, 1.0);
        \\}
    );
}

test "R14.3: post-processing pattern" {
    try testShader("R14.3",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(binding = 0, std140) uniform U { vec2 resolution; float time; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / u.resolution;
        \\    vec4 c = texture(tex, uv);
        \\    float gray = dot(c.rgb, vec3(0.299, 0.587, 0.114));
        \\    c.rgb = mix(c.rgb, vec3(gray), 0.5 + 0.5 * sin(u.time));
        \\    fragColor = c;
        \\}
    );
}

test "R14.4: texture + uniform block + functions" {
    try testShader("R14.4",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(binding = 1, std140) uniform U { vec3 tint; float intensity; vec2 offset; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\vec3 apply_tint(vec3 color, vec3 tint, float intensity) {
        \\    return mix(color, color * tint, intensity);
        \\}
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
        \\    vec4 c = texture(tex, uv + u.offset);
        \\    c.rgb = apply_tint(c.rgb, u.tint, u.intensity);
        \\    fragColor = c;
        \\}
    );
}

test "R14.5: CRT-like shader pattern" {
    try testShader("R14.5",
        \\#version 450
        \\layout(binding = 0) uniform sampler2D tex;
        \\layout(binding = 1, std140) uniform U { vec2 resolution; float time; float curvature; } u;
        \\layout(location = 0) out vec4 fragColor;
        \\vec2 curve_uv(vec2 uv) {
        \\    uv = uv * 2.0 - 1.0;
        \\    vec2 offset = abs(uv.yx) / vec2(u.curvature);
        \\    uv = uv + uv * offset * offset;
        \\    uv = uv * 0.5 + 0.5;
        \\    return uv;
        \\}
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / u.resolution;
        \\    vec2 curved = curve_uv(uv);
        \\    vec4 c = texture(tex, curved);
        \\    float scanline = sin(curved.y * u.resolution.y * 3.14159) * 0.04;
        \\    c.rgb -= scanline;
        \\    fragColor = c;
        \\}
    );
}

// ============================================================================
// File-based tests — read shaders from tests/spirv_cross_shaders/
// These are from spirv-cross's test suite (Apache-2.0).
// ============================================================================

test "file: basic.frag" {
    const source = @embedFile("spirv_cross_shaders/basic.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("basic.frag", zero_source);
}

test "file: sampler.frag" {
    const source = @embedFile("spirv_cross_shaders/sampler.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("sampler.frag", zero_source);
}

test "file: mix.frag" {
    const source = @embedFile("spirv_cross_shaders/mix.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("mix.frag", zero_source);
}

test "file: ground.frag" {
    const source = @embedFile("spirv_cross_shaders/ground.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("ground.frag", zero_source);
}

test "file: constant-composites.frag" {
    const source = @embedFile("spirv_cross_shaders/constant-composites.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("constant-composites.frag", zero_source);
}

test "file: flush_params.frag" {
    const source = @embedFile("spirv_cross_shaders/flush_params.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("flush_params.frag", zero_source);
}

test "file: swizzle.frag" {
    const source = @embedFile("spirv_cross_shaders/swizzle.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("swizzle.frag", zero_source);
}

test "file: selection-block-dominator.frag" {
    const source = @embedFile("spirv_cross_shaders/selection-block-dominator.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("selection-block-dominator.frag", zero_source);
}

test "file: switch-unreachable-break.frag" {
    const source = @embedFile("spirv_cross_shaders/switch-unreachable-break.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("switch-unreachable-break.frag", zero_source);
}

test "file: switch-unsigned-case.frag" {
    const source = @embedFile("spirv_cross_shaders/switch-unsigned-case.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("switch-unsigned-case.frag", zero_source);
}

test "file: for-loop-init.frag" {
    const source = @embedFile("spirv_cross_shaders/for-loop-init.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("for-loop-init.frag", zero_source);
}

test "file: false-loop-init.frag" {
    const source = @embedFile("spirv_cross_shaders/false-loop-init.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("false-loop-init.frag", zero_source);
}

test "file: constant-array.frag" {
    const source = @embedFile("spirv_cross_shaders/constant-array.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("constant-array.frag", zero_source);
}

test "file: front-facing.frag" {
    const source = @embedFile("spirv_cross_shaders/front-facing.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("front-facing.frag", zero_source);
}

test "file: complex-expression-in-access-chain.frag" {
    const source = @embedFile("spirv_cross_shaders/complex-expression-in-access-chain.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("complex-expression-in-access-chain.frag", zero_source);
}

test "file: ubo_layout.frag" {
    const source = @embedFile("spirv_cross_shaders/ubo_layout.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("ubo_layout.frag", zero_source);
}

test "file: scalar-refract-reflect.frag" {
    const source = @embedFile("spirv_cross_shaders/scalar-refract-reflect.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("scalar-refract-reflect.frag", zero_source);
}

test "file: texel-fetch-offset.frag" {
    const source = @embedFile("spirv_cross_shaders/texel-fetch-offset.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("texel-fetch-offset.frag", zero_source);
}

test "file: sampler-proj.frag" {
    const source = @embedFile("spirv_cross_shaders/sampler-proj.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("sampler-proj.frag", zero_source);
}

test "file: array-lut-no-loop-variable.frag" {
    const source = @embedFile("spirv_cross_shaders/array-lut-no-loop-variable.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("array-lut-no-loop-variable.frag", zero_source);
}

test "file: composite-extract-forced-temporary.frag" {
    const source = @embedFile("spirv_cross_shaders/composite-extract-forced-temporary.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("composite-extract-forced-temporary.frag", zero_source);
}

test "file: unary-enclose.frag" {
    const source = @embedFile("spirv_cross_shaders/unary-enclose.frag");
    const zero_source: [:0]const u8 = std.mem.sliceTo(source, 0);
    try testShader("unary-enclose.frag", zero_source);
}
