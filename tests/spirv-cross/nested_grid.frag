#version 450

// Test: nested for loops building a 2D pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float val = 0.0;

    for (int iy = 0; iy < 4; iy++) {
        for (int ix = 0; ix < 4; ix++) {
            vec2 cellCenter = (vec2(float(ix), float(iy)) + 0.5) / 4.0;
            float d = distance(uv, cellCenter);
            val += 0.1 / (d * 16.0 + 0.5);
        }
    }

    val = clamp(val, 0.0, 1.0);
    gl_FragColor = vec4(val, val * 0.8, val * 0.6, 1.0);
}
