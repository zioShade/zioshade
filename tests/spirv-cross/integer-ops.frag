#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test integer operations
    int a = int(uv.x * 100.0);
    int b = int(uv.y * 50.0);
    int c = a / max(b, 1);
    int d = a % max(b + 1, 1);
    int e = (a << 2) & 0xFF;
    int f = (a | b) ^ 0x55;
    fragColor = vec4(float(c) / 100.0, float(d) / 50.0, float(e) / 255.0, float(f) / 255.0);
}
