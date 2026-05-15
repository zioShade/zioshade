#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test negate and not operations
    float a = -uv.x;
    float b = -uv.y;
    int c = -1;
    int d = ~c;
    fragColor = vec4(a + 1.0, b + 1.0, float(d) * 0.5, 1.0);
}
