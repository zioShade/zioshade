#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Integer operations: bitwise AND, OR, XOR, shift
    int a = int(uv.x * 255.0);
    int b = int(uv.y * 255.0);
    int and_val = a & b;
    int or_val = a | b;
    int xor_val = a ^ b;
    int shift_val = a >> 2;

    fragColor = vec4(
        float(and_val) / 255.0,
        float(or_val) / 255.0,
        float(xor_val) / 255.0,
        float(shift_val) / 255.0
    );
}
