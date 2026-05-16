#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Integer bitwise operations
    int a = int(uv.x * 255.0);
    int b = int(uv.y * 255.0);

    int or_val = a | b;
    int and_val = a & b;
    int xor_val = a ^ b;
    int not_val = ~a;
    int shl_val = a << 2;
    int shr_val = a >> 3;

    float r = float(or_val & 255) / 255.0;
    float g = float(and_val & 255) / 255.0;
    float bl = float(xor_val & 255) / 255.0;

    fragColor = vec4(r, g, bl, 1.0);
}
