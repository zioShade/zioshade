#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Simple oil painting effect
    float k = 8.0;
    vec2 cell = floor(uv * k);
    vec2 f = fract(uv * k);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
    vec3 base = vec3(0.5) + 0.4 * cos(6.28 * (h + vec3(0.0, 0.33, 0.67)));
    float brightness = 0.5 + 0.3 * sin(cell.x * 0.5) * cos(cell.y * 0.7);
    // Stroke direction varies per cell
    float stroke_dir = h * 3.14;
    float stroke = abs(f.x * cos(stroke_dir) + f.y * sin(stroke_dir));
    stroke = smoothstep(0.5, 0.48, stroke);
    vec3 col = base * brightness * (0.7 + 0.3 * stroke);
    fragColor = vec4(col, 1.0);
}
