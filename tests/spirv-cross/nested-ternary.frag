#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test nested ternary chains
    float x = uv.x;
    float y = uv.y;
    float a = x > 0.5 ? (y > 0.5 ? 1.0 : 0.75) : (y > 0.5 ? 0.5 : 0.25);
    float b = x < 0.25 ? 0.0 : (x < 0.5 ? 0.33 : (x < 0.75 ? 0.66 : 1.0));
    fragColor = vec4(a, b, a * b, 1.0);
}
