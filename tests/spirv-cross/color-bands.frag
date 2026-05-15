#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Color bands using floor/mod
    float band = floor(uv.x * 8.0);
    float r = sin(band * 0.5) * 0.5 + 0.5;
    float g = sin(band * 0.7 + 1.0) * 0.5 + 0.5;
    float b = sin(band * 0.3 + 2.0) * 0.5 + 0.5;
    fragColor = vec4(r, g, b, 1.0);
}
