#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test floor, ceil, fract, mod
    float a = floor(uv.x * 10.0);
    float b = ceil(uv.y * 5.0);
    float c = fract(uv.x * 3.0);
    float d = mod(uv.y * 7.0, 3.0);
    float e = sign(uv.x - 0.5);
    float f = abs(e);
    fragColor = vec4(a / 10.0, b / 5.0, c, d / 3.0);
}
