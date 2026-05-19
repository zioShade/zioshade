#version 450

// Test: max/min with vectors
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 a = uv * 2.0 - 1.0;
    vec2 b = vec2(0.0);

    vec2 mx = max(a, b);
    vec2 mn = min(a, b);
    vec2 cl = clamp(a, -0.5, 0.5);

    gl_FragColor = vec4(mx * 0.5 + 0.5, mn * 0.5 + 0.5);
}
