#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test nested function calls
    float a = sin(u * 3.14);
    float b = cos(u * 2.0);
    float c = abs(a * b);
    float d = sqrt(max(c, 0.001));
    float e = pow(max(d, 0.001), 0.5);
    fragColor = vec4(a, b, c, e);
}
