#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test uint operations
    uint a = uint(u * 100.0);
    uint b = a + 1u;
    uint c = b - a;
    uint d = a * 2u;
    uint e = d / 3u;
    uint f = d % 5u;
    fragColor = vec4(float(b) / 200.0, float(c), float(e) / 100.0, float(f) / 50.0);
}
