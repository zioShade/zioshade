#version 430
layout(location = 0) out vec4 FragColor;

// Test: for loop with continue
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float sum = 0.0;
    for (int i = 0; i < 8; i++) {
        if (i % 2 == 0) continue;
        sum += float(i) * uv.x / 8.0;
    }
    FragColor = vec4(sum, uv.y, 1.0 - sum, 1.0);
}
