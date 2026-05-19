#version 450

// Test: loop with step-based coloring
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;

    float level = 0.0;
    for (int i = 0; i < 5; i++) {
        if (x > float(i) / 5.0) {
            level = float(i) / 5.0;
        }
    }

    vec3 col = vec3(level, level * 0.5, 1.0 - level) * smoothstep(0.0, 0.3, uv.y);
    gl_FragColor = vec4(col, 1.0);
}
