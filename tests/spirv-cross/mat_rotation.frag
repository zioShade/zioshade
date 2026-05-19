#version 450

// Test: matrix column operations
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    mat2 m = mat2(1.0, 0.0, 0.0, 1.0);
    m[0] = vec2(cos(uv.x * 3.14), sin(uv.x * 3.14));
    m[1] = vec2(-sin(uv.y * 3.14), cos(uv.y * 3.14));

    vec2 p = m * (uv * 2.0 - 1.0);

    gl_FragColor = vec4(p * 0.5 + 0.5, 0.0, 1.0);
}
