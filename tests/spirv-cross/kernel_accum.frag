#version 450

// Test: loop unrolling pattern with accumulation
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float result = 0.0;
    for (int i = 0; i < 8; i++) {
        float x = float(i) / 8.0;
        float weight = 1.0 / (1.0 + abs(uv.x - x) * 8.0);
        result += weight * sin(x * 6.28);
    }
    result /= 8.0;

    gl_FragColor = vec4(result * 0.5 + 0.5, uv.y, abs(result), 1.0);
}
