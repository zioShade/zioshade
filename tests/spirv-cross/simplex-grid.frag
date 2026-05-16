#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Simplex-like grid pattern
    vec2 p = uv * 5.0;

    // Skew input space
    float skew = (p.x + p.y) * 0.36602540378;
    vec2 skewed = p + vec2(skew);

    vec2 ip = floor(skewed);
    vec2 fp = fract(skewed);

    // Triangle vertices
    float h1 = fract(sin(dot(ip, vec2(127.1, 311.7))) * 43758.5453);
    float h2 = fract(sin(dot(ip + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5453);
    float h3 = fract(sin(dot(ip + vec2(0.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);

    float d1 = length(fp);
    float d2 = length(fp - vec2(1.0, 0.0));
    float d3 = length(fp - vec2(0.0, 1.0));

    float val = min(d1, min(d2, d3));
    float col = smoothstep(0.15, 0.1, val);

    vec3 color = mix(vec3(0.1), vec3(0.3 + h1 * 0.4, 0.5 + h2 * 0.3, 0.7 + h3 * 0.2), col);

    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
