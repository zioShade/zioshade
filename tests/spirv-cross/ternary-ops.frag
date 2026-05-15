#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test ternary operator with different types
    float a = u > 0.5 ? u * 2.0 : u * 3.0;
    bool b = u > 0.5;
    float c = b ? 1.0 : -1.0;
    int d = int(u * 10.0);
    int e = d > 5 ? d + 1 : d - 1;
    fragColor = vec4(a, c, float(e), 1.0);
}
