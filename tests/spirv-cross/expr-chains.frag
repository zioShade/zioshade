#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test arithmetic expression chains
    float a = uv.x * 2.0 - 1.0;
    float b = uv.y * 3.0 + 0.5;
    float c = a * a + b * b;
    float d = sqrt(c);
    float e = sin(a * 3.14159) + cos(b * 3.14159);
    float f = abs(e) * d;
    float g = pow(max(f, 0.001), 0.5);
    fragColor = vec4(g, f * 0.5, d, 1.0);
}
