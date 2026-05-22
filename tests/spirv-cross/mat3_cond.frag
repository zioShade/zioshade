#version 310 es
precision highp float;
out vec4 fragColor;

// Mat3 construction with conditional column assignment via subscript
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    mat3 m = mat3(
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0
    );

    // Modify a column based on condition
    if (uv.x > 0.5) {
        m[0] = vec3(cos(uv.x), sin(uv.x), 0.0);
    }
    if (uv.y > 0.5) {
        m[1] = vec3(-sin(uv.y), cos(uv.y), 0.0);
    }

    vec3 v = vec3(uv, 1.0);
    vec3 result = m * v;

    vec3 col = fract(result * 0.5 + 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
