#version 310 es
precision highp float;
out vec4 fragColor;

// Bicubic Hermite interpolation
float hermite(float t) {
    return t * t * (3.0 - 2.0 * t);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Smooth value noise with Hermite interpolation
    vec2 cell = floor(uv * 8.0);
    vec2 f = fract(uv * 8.0);
    float n00 = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    float n10 = fract(sin(dot(cell + vec2(1, 0), vec2(127.1, 311.7))) * 43758.5);
    float n01 = fract(sin(dot(cell + vec2(0, 1), vec2(127.1, 311.7))) * 43758.5);
    float n11 = fract(sin(dot(cell + vec2(1, 1), vec2(127.1, 311.7))) * 43758.5);
    float fx = hermite(f.x);
    float fy = hermite(f.y);
    float n = mix(mix(n00, n10, fx), mix(n01, n11, fx), fy);
    vec3 col = vec3(n * 0.8, n * 0.6, n * 0.4);
    fragColor = vec4(col, 1.0);
}
