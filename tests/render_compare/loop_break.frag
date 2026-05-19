#version 430
layout(location = 0) out vec4 FragColor;

// Test: for loop with break
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float sum = 0.0;
    for (int i = 0; i < 10; i++) {
        sum += 0.1;
        if (sum > uv.x) break;
    }
    FragColor = vec4(sum, uv.y, 1.0 - sum, 1.0);
}
