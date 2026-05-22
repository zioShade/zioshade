#version 310 es
precision highp float;
out vec4 fragColor;

// Complex swizzle read-write chains with conditionals
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    vec4 a = vec4(uv, 1.0 - uv);
    if (uv.x > 0.5) {
        a.xw = a.yz;  // swizzle write
    } else {
        a.yz = a.xw;  // different swizzle write
    }

    // Chain swizzle operations
    vec4 b = a;
    b.xyz = b.zyx;  // reverse xyz
    if (uv.y > 0.5) {
        b.w = b.x + b.y;
    }

    // Swizzle from function-like expression
    vec4 c = vec4(sin(uv.x), cos(uv.y), uv.x * uv.y, 1.0);
    c.xz = c.yw;

    vec3 col = (a + b + c).xyz * 0.33;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
