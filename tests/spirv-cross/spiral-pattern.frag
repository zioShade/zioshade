#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Spiral pattern
    vec2 centered = uv * 2.0 - 1.0;
    float r = length(centered);
    float theta = atan(centered.y / centered.x);
    float spiral = fract((theta / 6.28318530 + r) * 3.0);
    fragColor = vec4(spiral, spiral * 0.8, spiral * 0.5, 1.0);
}
