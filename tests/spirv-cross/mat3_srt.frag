#version 450

// Test: matrix identity, scale, translation via mat3
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    // Identity
    mat3 id = mat3(1.0);
    // Scale
    mat3 sc = mat3(
        uv.x, 0.0, 0.0,
        0.0, uv.y, 0.0,
        0.0, 0.0, 1.0
    );

    vec3 p = vec3(uv, 1.0);
    vec3 r1 = id * p;
    vec3 r2 = sc * p;

    gl_FragColor = vec4(r2.xy, r2.z * 0.5, 1.0);
}
