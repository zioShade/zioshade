#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Nested loop with break and continue
    float val = 0.0;
    for (int y = 0; y < 5; y++) {
        for (int x = 0; x < 5; x++) {
            if (x == y) continue;  // skip diagonal
            if (x + y > 7) break; // stop past threshold
            vec2 offset = vec2(float(x) - 2.0, float(y) - 2.0) * 0.3;
            float d = length(uv - offset);
            val += smoothstep(0.15, 0.1, d) * 0.1;
        }
    }
    vec3 col = vec3(val, val * 0.7, val * 0.3);
    fragColor = vec4(col, 1.0);
}
