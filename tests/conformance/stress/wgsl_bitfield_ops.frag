#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    int a = int(uv.x * 255.0);
    int b = int(uv.y * 255.0);

    int shifted_left = a << 2;
    int shifted_right = b >> 1;
    int and_result = a & b;
    int or_result = a | b;
    int xor_result = a ^ b;
    int not_result = ~a;

    float r = float(shifted_left & 255) / 255.0;
    float g = float(and_result | 1) / 255.0;
    float b2 = float(xor_result ^ not_result & 255) / 255.0;
    fragColor = vec4(r, g, b2, 1.0);
}
