#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // Fern / leaf venation pattern
    vec3 col = vec3(0.15, 0.25, 0.1);
    // Central vein
    float vein_main = smoothstep(0.03, 0.01, abs(uv.x - 5.0)) * step(2.0, uv.y) * step(uv.y, 10.0);
    col += vec3(0.1, 0.2, 0.0) * vein_main;
    // Side veins (alternating)
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float y_start = 3.0 + fi * 0.8;
        float angle = 0.5 * (1.0 - fi / 8.0);
        // Left vein
        float left_vein = uv.y - y_start - (5.0 - uv.x) * angle;
        float lv = smoothstep(0.02, 0.01, abs(left_vein)) * step(5.0 - 3.0 * (1.0 - fi / 8.0), uv.x) * step(uv.x, 5.0);
        // Right vein
        float right_vein = uv.y - y_start - (uv.x - 5.0) * angle;
        float rv = smoothstep(0.02, 0.01, abs(right_vein)) * step(5.0, uv.x) * step(uv.x, 5.0 + 3.0 * (1.0 - fi / 8.0));
        col += vec3(0.1, 0.18, 0.0) * (lv + rv);
    }
    fragColor = vec4(col, 1.0);
}
