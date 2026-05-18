#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mutual recursion
float funcA(int n);
float funcB(int n);

float funcA(int n) {
    if (n <= 0) return 1.0;
    return float(n) * funcB(n - 1);
}

float funcB(int n) {
    if (n <= 0) return 1.0;
    return float(n) * funcA(n - 1);
}

void main() {
    int n = int(uv.x * 4.0) + 1;
    float f = funcA(n);
    fragColor = vec4(clamp(f / 120.0, 0.0, 1.0), uv.y, 0.0, 1.0);
}
