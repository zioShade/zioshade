#version 450

// Test: matrix-vector multiplication chain
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    mat2 scale = mat2(2.0, 0.0, 0.0, 2.0);
    mat2 rot = mat2(0.707, -0.707, 0.707, 0.707);
    vec2 p = uv * 2.0 - 1.0;

    vec2 r1 = scale * p;
    vec2 r2 = rot * r1;

    gl_FragColor = vec4(r2 * 0.5 + 0.5, 0.0, 1.0);
}
