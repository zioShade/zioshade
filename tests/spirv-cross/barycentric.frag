#version 450

// Test: face determinant check (backface culling logic)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    // Triangle vertices
    vec2 v0 = vec2(0.2, 0.2);
    vec2 v1 = vec2(0.8, 0.2);
    vec2 v2 = vec2(0.5, 0.8);

    vec2 e0 = v1 - v0;
    vec2 e1 = v2 - v0;
    float det = e0.x * e1.y - e0.y * e1.x;

    // Barycentric coordinates
    vec2 vp = uv - v0;
    float u_bary = (e1.y * vp.x - e1.x * vp.y) / det;
    float v_bary = (-e0.y * vp.x + e0.x * vp.y) / det;
    float w_bary = 1.0 - u_bary - v_bary;

    bool inside = u_bary >= 0.0 && v_bary >= 0.0 && w_bary >= 0.0;
    vec3 col = inside ? vec3(u_bary, v_bary, w_bary) : vec3(0.1);

    gl_FragColor = vec4(col, 1.0);
}
