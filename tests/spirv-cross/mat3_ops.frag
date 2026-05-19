#version 450

// Test: mat3 operations
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    mat3 m = mat3(
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0
    );

    vec3 v = vec3(uv, 0.5);
    vec3 r = m * v;

    // Scale a column
    m[1] *= uv.x;
    vec3 r2 = m * v;

    gl_FragColor = vec4(r2, 1.0);
}
