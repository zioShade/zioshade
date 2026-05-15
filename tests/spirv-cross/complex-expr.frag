#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test complex expressions with multiple operators
    float a = (uv.x + uv.y) * (uv.x - uv.y);
    float b = uv.x / max(uv.y, 0.001);
    float c = fract(a + b);
    float d = abs(c - 0.5) * 2.0;
    float e = sqrt(max(d, 0.0));
    fragColor = vec4(e, d, c, 1.0);
}
