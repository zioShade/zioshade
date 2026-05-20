#version 310 es
precision highp float;
out vec4 fragColor;

// Micro-cellular / biological microscope view
void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    vec3 col = vec3(0.05, 0.1, 0.05);
    // Multiple cells
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        vec2 center = vec2(
            fract(sin(fi * 127.1) * 43758.5) * 15.0,
            fract(sin(fi * 311.7) * 43758.5) * 15.0
        );
        float d = length(uv - center);
        float size = 0.5 + fract(sin(fi * 74.3) * 43758.5) * 0.5;
        // Cell membrane
        float membrane = smoothstep(size + 0.02, size, d) * (1.0 - smoothstep(size - 0.05, size - 0.03, d));
        // Nucleus
        float nucleus = smoothstep(size * 0.3 + 0.01, size * 0.3, d);
        vec3 cell_col = vec3(0.3, 0.6, 0.3) * membrane + vec3(0.2, 0.4, 0.2) * nucleus;
        col += cell_col;
    }
    fragColor = vec4(col, 1.0);
}
