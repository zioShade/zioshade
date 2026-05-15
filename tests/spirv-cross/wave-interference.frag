#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Circular wave interference pattern
    vec2 p1 = vec2(0.3, 0.5);
    vec2 p2 = vec2(0.7, 0.5);
    float d1 = length(uv - p1);
    float d2 = length(uv - p2);
    float wave1 = sin(d1 * 40.0) * 0.5 + 0.5;
    float wave2 = sin(d2 * 40.0) * 0.5 + 0.5;
    float interference = (wave1 + wave2) * 0.5;
    fragColor = vec4(interference, interference * 0.8, interference * 0.6, 1.0);
}
