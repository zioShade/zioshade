#version 430
layout(location = 0) out vec4 FragColor;

// Test: loop with break+continue and SMod
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float sum = 0.0;
    int count = 0;
    for (int i = 0; i < 12; i++) {
        if (i % 3 == 0) continue;
        if (sum > uv.x * 2.0) break;
        sum += float(i) * 0.08;
        count += 1;
    }
    float brightness = sum * float(count) * 0.05;
    FragColor = vec4(vec3(brightness), 1.0);
}
