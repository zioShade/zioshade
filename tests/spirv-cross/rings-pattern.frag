#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Normalized device coordinates edge detection
    vec2 p = uv * 2.0 - 1.0;

    // Concentric rings with anti-aliasing
    float d = length(p);
    float ring = sin(d * 20.0) * 0.5 + 0.5;

    // Smooth edge
    ring *= smoothstep(1.0, 0.5, d);

    // Angular color variation
    float angle = atan(p.y, p.x);
    vec3 col = ring * vec3(
        sin(angle) * 0.5 + 0.5,
        cos(angle * 2.0) * 0.5 + 0.5,
        sin(angle * 3.0 + 1.0) * 0.5 + 0.5
    );

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
