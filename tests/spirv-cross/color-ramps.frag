#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Stepped color ramps
    float r = floor(uv.x * 4.0) / 4.0;
    float g = floor(uv.y * 4.0) / 4.0;
    float b = floor((uv.x + uv.y) * 4.0) / 8.0;
    fragColor = vec4(r, g, b, 1.0);
}
