#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Celtic interlace pattern
    float scale = 2.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // Over-under weaving
    float diag1 = abs(f.x - f.y);
    float diag2 = abs(f.x + f.y - 1.0);
    float band = 0.15;
    float ribbon1 = smoothstep(band + 0.02, band, diag1) * (1.0 - smoothstep(band - 0.02, band - 0.04, diag1));
    float ribbon2 = smoothstep(band + 0.02, band, diag2) * (1.0 - smoothstep(band - 0.02, band - 0.04, diag2));
    // Color based on position
    vec3 gold = vec3(0.85, 0.7, 0.25);
    vec3 green = vec3(0.15, 0.4, 0.2);
    vec3 col = vec3(0.05, 0.08, 0.12);
    col += gold * ribbon1;
    col += green * ribbon2;
    fragColor = vec4(col, 1.0);
}
