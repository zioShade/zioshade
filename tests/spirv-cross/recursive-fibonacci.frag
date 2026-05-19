#version 450

layout(location = 0) out vec4 fragColor;

// Test recursive function (conditional recursion)
float fibonacci(float n) {
    if (n <= 1.0) return n;
    return fibonacci(n - 1.0) + fibonacci(n - 2.0);
}

void main() {
    float f = fibonacci(5.0);
    fragColor = vec4(vec3(f / 5.0), 1.0);
}
