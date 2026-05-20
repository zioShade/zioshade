#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    int a = int(gl_FragCoord.x);
    int b = int(gl_FragCoord.y);
    // Complex integer operations
    int sum = a + b;
    int diff = a - b;
    int prod = a * 2;
    int shifted = a >> 2;
    int ored = a | b;
    int anded = a & 0xFF;
    int xored = a ^ b;
    int negged = -a;
    int modded = a % 16;
    int clamped_val = clamp(a, 0, 255);
    int min_val = min(a, b);
    int max_val = max(a, b);
    int abs_val = abs(a - 128);
    float r = float(sum & 0xFF) / 255.0;
    float g = float(clamped_val) / 255.0;
    float b2 = float(abs_val) / 128.0;
    fragColor = vec4(r, g, b2, 1.0);
}
