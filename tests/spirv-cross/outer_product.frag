#version 450

// Test: outer product and matrix column access
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    vec2 a = vec2(uv.x, uv.y);
    vec2 b = vec2(0.5, 0.3);
    mat2 m = outerProduct(a, b);

    vec2 col0 = m[0];
    vec2 col1 = m[1];

    float det = col0.x * col1.y - col0.y * col1.x;

    gl_FragColor = vec4(col0, col1.x, abs(det));
}
