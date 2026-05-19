#version 430
layout(location = 0) out vec4 FragColor;

// Test: face-based mix of two patterns
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float pattern1 = sin(uv.x * 20.0) * 0.5 + 0.5;
    float pattern2 = cos(uv.y * 20.0) * 0.5 + 0.5;
    float mask = step(0.5, sin(length(uv - 0.5) * 20.0));
    float result = mix(pattern1, pattern2, mask);
    FragColor = vec4(result, result * 0.8, result * 0.6, 1.0);
}
