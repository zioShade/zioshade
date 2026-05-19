#version 430
layout(location = 0) out vec4 FragColor;

// Test: for loop with break and continue
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float sum = 0.0;
    for (int i = 0; i < 10; i++) {
        if (i % 3 == 0) continue;
        if (sum > uv.x) break;
        sum += float(i) * 0.05;
    }
    FragColor = vec4(clamp(sum, 0.0, 1.0), uv.y, 1.0 - sum, 1.0);
}
