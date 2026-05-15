#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test integer operations
    int i = int(u * 100.0);
    int a = i & 0xFF;
    int b = i | 0x100;
    int c = i ^ 0x55;
    int d = i << 2;
    int e = i >> 1;
    int f = ~i;
    fragColor = vec4(float(a + b), float(c + d), float(e + f), 1.0);
}
