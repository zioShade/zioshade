#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Brick pattern using mod and step
    float scale = 8.0;
    vec2 brick = floor(uv * scale);
    float offset = mod(brick.y, 2.0) * 0.5;
    vec2 centered = fract(uv * scale + vec2(offset, 0.0));
    float mortar = step(0.05, centered.x) * step(0.05, centered.y);
    vec3 color = mix(vec3(0.6, 0.55, 0.5), vec3(0.8, 0.3, 0.2), mortar);
    fragColor = vec4(color, 1.0);
}
