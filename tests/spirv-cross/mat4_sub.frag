#version 310 es
precision highp float;
out vec4 fragColor;

// Mat4 column subscript write in loop
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    mat4 m = mat4(
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
    );

    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float angle = uv.x * 3.14 + fi * 1.57;
        m[i] = vec4(cos(angle), sin(angle), fi * 0.5, 1.0);
    }

    vec4 result = m * vec4(uv, 0.0, 1.0);
    vec3 col = fract(result.xyz * 0.5 + 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
