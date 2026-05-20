#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Camouflage digital pattern (MARPAT style)
    float scale = 3.0;
    vec2 cell = floor(uv * scale);
    vec2 f = fract(uv * scale);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // Micro-pattern
    float micro = fract(sin(dot(f * 10.0 + cell * 100.0, vec2(127.1, 311.7))) * 43758.5);
    // Color selection
    vec3 green = vec3(0.25, 0.35, 0.15);
    vec3 brown = vec3(0.45, 0.35, 0.2);
    vec3 tan = vec3(0.6, 0.55, 0.35);
    vec3 dark = vec3(0.15, 0.18, 0.1);
    vec3 col;
    if (h < 0.25) col = green;
    else if (h < 0.5) col = brown;
    else if (h < 0.75) col = tan;
    else col = dark;
    // Add micro-texture
    col *= 0.85 + micro * 0.15;
    fragColor = vec4(col, 1.0);
}
