#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Elephant skin texture
    float scale = 8.0;
    vec2 cell = floor(uv * scale);
    vec2 f = fract(uv * scale);
    float n = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // Wrinkles
    float wrinkle1 = sin(f.x * 15.0 + n * 6.28) * 0.5 + 0.5;
    float wrinkle2 = sin(f.y * 12.0 + n * 3.14) * 0.5 + 0.5;
    float wrinkles = wrinkle1 * wrinkle2;
    vec3 gray = vec3(0.5, 0.48, 0.45);
    vec3 dark = vec3(0.3, 0.28, 0.25);
    vec3 col = mix(dark, gray, wrinkles);
    fragColor = vec4(col, 1.0);
}
