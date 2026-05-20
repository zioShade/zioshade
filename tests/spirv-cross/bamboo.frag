#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Bamboo forest
    vec3 col = vec3(0.15, 0.25, 0.1); // dark background
    // Bamboo stalks
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float x = 1.0 + fi * 2.0 + sin(fi * 3.7) * 0.5;
        float sway = sin(uv.y * 0.3 + fi * 1.7) * 0.05;
        float stalk = smoothstep(0.06, 0.04, abs(uv.x - x - sway));
        // Segments (nodes)
        float node = smoothstep(0.01, 0.005, abs(fract(uv.y * 0.8 + fi * 0.3)));
        vec3 bamboo = vec3(0.4, 0.55, 0.15) + vec3(0.05) * node;
        col = mix(col, bamboo, stalk);
    }
    // Leaves
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        vec2 leaf_pos = vec2(
            fract(sin(fi * 127.1) * 43758.5) * 8.0 + 1.0,
            fract(sin(fi * 311.7) * 43758.5) * 8.0 + 2.0
        );
        float d = length((uv - leaf_pos) * vec2(2.0, 0.5));
        float leaf = smoothstep(0.15, 0.1, d);
        col = mix(col, vec3(0.25, 0.5, 0.1), leaf);
    }
    fragColor = vec4(col, 1.0);
}
