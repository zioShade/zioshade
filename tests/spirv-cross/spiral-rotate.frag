#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Spiral with rotation
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float angle = atan(p.y, p.x);

    // Archimedean spiral
    float spiral_r = angle / 6.28318;
    float spiral = fract(spiral_r - r * 3.0);

    float col = smoothstep(0.4, 0.5, spiral) * smoothstep(0.6, 0.5, spiral);
    col *= smoothstep(1.0, 0.1, r);

    vec3 color = vec3(col * 0.8, col * 0.5, col);
    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
