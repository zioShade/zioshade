#version 450

// Test nested loops with break and continue
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 5; j++) {
            if (i == j) continue;
            if (i + j > 7) break;
            sum += float(i * j) / 25.0;
        }
    }
    float r = sum * uv.x;
    float g = sum * uv.y;
    float b = sum * 0.5;
    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
}
