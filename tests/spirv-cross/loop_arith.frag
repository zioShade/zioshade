#version 450

// Test: loop with complex index arithmetic
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float sum = 0.0;
    float prod = 1.0;

    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float w = 1.0 / (fi + 1.0);
        sum += uv.x * w;
        prod *= mix(0.9, 1.1, uv.y);
    }

    float r = clamp(sum, 0.0, 1.0);
    float g = clamp(prod / pow(1.1, 6.0), 0.0, 1.0);
    gl_FragColor = vec4(r, g, (r + g) * 0.5, 1.0);
}
