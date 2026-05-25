// Tests: deeply nested function call chain
#version 450
layout(location = 0) out vec4 fragColor;

float f0(float x) { return x + 0.1; }
float f1(float x) { return f0(x) * 2.0; }
float f2(float x) { return f1(x) - 0.5; }
float f3(float x) { return f2(x) * f2(x); }
float f4(float x) { return f3(x) + f1(x); }

void main() {
    float r = f4(0.5);
    fragColor = vec4(vec3(fract(r)), 1.0);
}
