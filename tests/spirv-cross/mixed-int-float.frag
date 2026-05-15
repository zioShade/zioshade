#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test mixed integer/float arithmetic
    int a = int(uv.x * 255.0);
    uint b = uint(uv.y * 255.0);
    float c = float(a) / 255.0;
    float d = float(b) / 255.0;
    int e = a + int(b);
    uint f = b - uint(a);
    float g = float(e) / 510.0;
    float h = float(f) / 255.0;
    fragColor = vec4(c, d, g, h);
}
