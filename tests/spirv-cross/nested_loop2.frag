#version 310 es
precision highp float;
out vec4 fragColor;

// Test: nested loops with break and continue
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec3 col = vec3(0.0);
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            vec2 center = (vec2(float(x), float(y)) + 0.5) * 0.5 - 1.0;
            float d = length(uv - center);
            if (d < 0.05) {
                col = vec3(1.0);
                break;
            }
            if (d > 0.5) continue;
            col += vec3(0.05) / (d + 0.1);
        }
    }
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
