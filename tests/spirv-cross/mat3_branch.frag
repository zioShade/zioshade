#version 310 es
precision highp float;
out vec4 fragColor;

// Test: matrix multiply in branch
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float angle = uv.x * 2.0;
    mat3 m = mat3(
        cos(angle), -sin(angle), 0.0,
        sin(angle), cos(angle), 0.0,
        0.0, 0.0, 1.0
    );
    vec3 p = vec3(uv, 1.0);
    vec3 transformed = m * p;
    vec3 col;
    if (transformed.x > 0.0) {
        col = vec3(0.3, 0.6, 0.9) * abs(transformed.x);
    } else {
        col = vec3(0.9, 0.4, 0.2) * abs(transformed.x);
    }
    fragColor = vec4(col, 1.0);
}
