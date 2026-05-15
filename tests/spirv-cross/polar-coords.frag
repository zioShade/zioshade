#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Polar coordinate conversion using single-arg atan
    vec2 centered = uv * 2.0 - 1.0;
    float r = length(centered);
    float theta = atan(centered.y / centered.x);
    float pattern = sin(r * 20.0 + theta * 5.0) * 0.5 + 0.5;
    fragColor = vec4(pattern, pattern * 0.7, pattern * 0.3, 1.0);
}
