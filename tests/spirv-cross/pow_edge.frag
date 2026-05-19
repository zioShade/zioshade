#version 450

// Test: pow with edge cases (0, 1, negative)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float a = pow(uv.x, 0.5);       // sqrt
    float b = pow(uv.x, 2.0);       // square
    float c = pow(max(uv.x, 0.001), 3.0); // cube
    float d = pow(uv.y, 1.0);       // identity

    gl_FragColor = vec4(a, b, clamp(c, 0.0, 1.0), d);
}
