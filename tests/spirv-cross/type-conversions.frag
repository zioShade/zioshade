#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test type conversions between int, uint, float, bool
    float f = u * 100.0;
    int i = int(f);
    uint u_val = uint(i);
    bool b = i > 50;
    float f2 = float(b);
    uint u2 = uint(b);
    fragColor = vec4(float(u_val) / 100.0, f2, float(u2), 1.0);
}
