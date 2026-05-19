#version 450

layout(location = 0) out vec4 fragColor;

// Test mutual recursion
float even(float n);
float odd(float n);

float even(float n) {
    if (n == 0.0) return 1.0;
    return odd(n - 1.0);
}

float odd(float n) {
    if (n == 0.0) return 0.0;
    return even(n - 1.0);
}

void main() {
    float e = even(4.0);
    float o = odd(3.0);
    fragColor = vec4(e, o, 0.0, 1.0);
}
