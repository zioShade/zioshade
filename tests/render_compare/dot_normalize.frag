#version 430
layout(location = 0) out vec4 FragColor;

// Test: dot product and normalize
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 a = normalize(uv * 2.0 - 1.0);
    vec2 b = vec2(1.0, 0.0);
    float d = dot(a, b);
    FragColor = vec4(d * 0.5 + 0.5, length(a), abs(a.y), 1.0);
}
