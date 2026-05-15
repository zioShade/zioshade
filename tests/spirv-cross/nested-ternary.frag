#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test ternary chains and nested conditionals
    float r = uv.x > 0.5 ? (uv.y > 0.5 ? 1.0 : 0.5) : 0.0;
    float g = uv.x < 0.5 ? (uv.y < 0.5 ? 0.8 : 0.3) : 0.1;
    float b = uv.x > uv.y ? 1.0 : (uv.y > 0.5 ? 0.7 : 0.2);
    fragColor = vec4(r, g, b, 1.0);
}
