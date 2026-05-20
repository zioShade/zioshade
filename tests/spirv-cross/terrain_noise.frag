#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Perlin-like noise gradient
    vec2 cell = floor(uv * 6.0);
    vec2 f = fract(uv * 6.0);
    // Smooth interpolation
    vec2 smooth_f = f * f * (3.0 - 2.0 * f);
    float n00 = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    float n10 = fract(sin(dot(cell + vec2(1, 0), vec2(127.1, 311.7))) * 43758.5);
    float n01 = fract(sin(dot(cell + vec2(0, 1), vec2(127.1, 311.7))) * 43758.5);
    float n11 = fract(sin(dot(cell + vec2(1, 1), vec2(127.1, 311.7))) * 43758.5);
    float nx1 = mix(n00, n10, smooth_f.x);
    float nx2 = mix(n01, n11, smooth_f.x);
    float n = mix(nx1, nx2, smooth_f.y);
    // Terrain coloring
    vec3 water = vec3(0.1, 0.3, 0.6);
    vec3 sand = vec3(0.8, 0.75, 0.5);
    vec3 grass = vec3(0.2, 0.6, 0.1);
    vec3 rock = vec3(0.5, 0.45, 0.4);
    vec3 snow = vec3(0.95);
    vec3 col = n < 0.3 ? water : n < 0.35 ? sand : n < 0.6 ? grass : n < 0.8 ? rock : snow;
    fragColor = vec4(col, 1.0);
}
