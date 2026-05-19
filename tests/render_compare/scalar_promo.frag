#version 430
layout(location = 0) out vec4 FragColor;

// Test min/max with mixed scalar/vector
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    vec2 v = uv * 2.0 - 1.0;
    vec2 lo = max(v, 0.0);
    vec2 hi = min(lo, 0.8);
    vec2 cl = clamp(v, -0.5, 0.5);
    FragColor = vec4(hi * 0.5 + 0.5, cl * 0.5 + 0.5);
}
