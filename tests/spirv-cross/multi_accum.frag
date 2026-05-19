#version 450

// Test: complex loop with multiple accumulators
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float sum = 0.0;
    float prod = 1.0;
    float maxVal = 0.0;

    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float v = sin(fi * 0.5 + uv.x * 3.0) * cos(fi * 0.3 + uv.y * 2.0);
        sum += v;
        prod *= (v * 0.5 + 0.5);
        maxVal = max(maxVal, abs(v));
    }

    float r = sum / 8.0 * 0.5 + 0.5;
    float g = clamp(pow(prod, 0.25), 0.0, 1.0);
    float b = maxVal;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), g, b, 1.0);
}
