#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.008;
    // Engraving pattern (intaglio lines)
    float val = sin(uv.x * 1.5) * cos(uv.y * 2.0) * 0.5 + 0.5;
    // Line density based on value
    float density = 5.0 + val * 20.0;
    float lines = sin(uv.y * density) * 0.5 + 0.5;
    // Cross-hatching for darker areas
    float cross = sin(uv.x * density * 0.7) * 0.5 + 0.5;
    float hatch = mix(lines, lines * cross, 1.0 - val);
    vec3 paper = vec3(0.95, 0.92, 0.85);
    vec3 ink = vec3(0.15, 0.12, 0.1);
    vec3 col = mix(ink, paper, hatch);
    fragColor = vec4(col, 1.0);
}
