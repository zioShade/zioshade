#version 450

// Test: loop with conditional accumulation
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float r = 0.0;
    float g = 0.0;
    float b = 0.0;

    for (int i = 0; i < 6; i++) {
        float f = float(i) / 6.0;
        if (i % 3 == 0) {
            r += f * uv.x;
        } else if (i % 3 == 1) {
            g += f * uv.y;
        } else {
            b += f * (uv.x + uv.y) * 0.5;
        }
    }

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
}
