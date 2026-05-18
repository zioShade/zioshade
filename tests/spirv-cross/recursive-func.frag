#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test recursive function (conditional recursion)
float factorial(int n) {
    if (n <= 1) return 1.0;
    return float(n) * factorial(n - 1);
}

void main() {
    int n = int(uv.x * 5.0) + 1;
    float f = factorial(n);
    fragColor = vec4(clamp(f / 120.0, 0.0, 1.0), uv.y, 0.0, 1.0);
}
