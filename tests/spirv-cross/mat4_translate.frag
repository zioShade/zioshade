#version 450

// Test: mat4 construction and multiplication
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    mat4 m = mat4(
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        uv.x, uv.y, 0.0, 1.0
    );

    vec4 v = vec4(0.5, 0.5, 0.0, 1.0);
    vec4 r = m * v;

    gl_FragColor = vec4(r.xy, 0.5, 1.0);
}
