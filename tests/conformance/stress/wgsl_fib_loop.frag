// Tests: loop with multiple phi variables (Fibonacci-like)
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float a = 0.0;
    float b = 1.0;
    for (int i = 0; i < 20; i++) {
        float c = a + b;
        a = b;
        b = c;
    }
    fragColor = vec4(vec3(fract(b * 0.01)), 1.0);
}
