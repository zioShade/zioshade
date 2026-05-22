#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Matrix operations in conditional branches
    float angle = uv.x * 3.14159;
    float ca = cos(angle);
    float sa = sin(angle);

    mat2 rot = mat2(ca, sa, -sa, ca);
    mat2 scale = mat2(2.0, 0.0, 0.0, 2.0);

    vec2 p;
    if (uv.y > 0.5) {
        p = rot * uv;
    } else {
        p = scale * uv;
    }

    // Second conditional with matrix
    mat2 m;
    if (p.x > 0.5) {
        m = rot * scale;
    } else {
        m = scale * rot;
    }
    vec2 q = m * p;

    // Swizzle with conditional
    vec4 col;
    if (q.x > q.y) {
        col = vec4(q.x, q.y, 0.0, 1.0);
        col.xz = col.yx;  // swizzle write
    } else {
        col = vec4(q.y, q.x, 1.0, 1.0);
        col.yw = col.xz;  // swizzle write
    }

    fragColor = clamp(col, 0.0, 1.0);
}
