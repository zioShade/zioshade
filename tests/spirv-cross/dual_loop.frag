#version 450

// Test: dual loop with shared state
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float sum1 = 0.0;
    float sum2 = 0.0;

    for (int i = 0; i < 5; i++) {
        sum1 += sin(float(i) * uv.x) * 0.2;
    }

    for (int j = 0; j < 3; j++) {
        sum2 += cos(float(j) * uv.y) * 0.3;
    }

    gl_FragColor = vec4(clamp(sum1, 0.0, 1.0), clamp(sum2, 0.0, 1.0), clamp(sum1 + sum2, 0.0, 1.0), 1.0);
}
