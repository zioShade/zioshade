#version 310 es
precision highp float;
out vec4 fragColor;

// Dynamic column index on matrix write
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    mat3 m = mat3(
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0
    );

    int col = int(uv.x * 2.0);
    col = clamp(col, 0, 2);
    m[col] = vec3(uv.x, uv.y, 0.0);

    vec3 result = m * vec3(uv, 1.0);
    vec3 col_out = fract(result * 0.5 + 0.5);
    fragColor = vec4(clamp(col_out, 0.0, 1.0), 1.0);
}
