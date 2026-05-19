#version 450

// Test: conditional assignment in loop
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float best = 999.0;
    int bestIdx = 0;

    for (int i = 0; i < 5; i++) {
        float fi = float(i) / 5.0;
        float d = abs(uv.x - fi);
        if (d < best) {
            best = d;
            bestIdx = i;
        }
    }

    float r = float(bestIdx) / 5.0;
    float g = best;
    float b = smoothstep(0.0, 0.2, best);

    gl_FragColor = vec4(r, g, b, 1.0);
}
