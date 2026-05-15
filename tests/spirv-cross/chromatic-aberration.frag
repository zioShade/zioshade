#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Chromatic aberration effect
    vec2 centered = uv - vec2(0.5);
    float d = length(centered);
    vec2 dir = normalize(centered + vec2(0.001));
    float offset = d * 0.05;
    float r = 0.5 + 0.5 * sin(d * 10.0 + uv.x * 5.0);
    float g = 0.5 + 0.5 * sin(d * 10.0 + uv.x * 5.0 + 2.094);
    float b = 0.5 + 0.5 * sin(d * 10.0 + uv.x * 5.0 + 4.188);
    fragColor = vec4(r * (1.0 - offset), g, b * (1.0 + offset), 1.0);
}
