#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Concentric rings
    float d = length(uv - vec2(0.5));
    float ring = abs(fract(d * 20.0) - 0.5) * 2.0;
    float mask = step(0.5, d) * step(d, 0.8);
    vec3 color = vec3(ring * mask);
    fragColor = vec4(color, 1.0);
}
