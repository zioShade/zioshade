#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Function chain — exercises 3-deep function call chain with parameter passing
float func3(float x) { return x * x; }
float func2(float x) { return func3(x) + 1.0; }
float func1(float x) { return func2(x + 0.5); }

void main() {
    float r = func1(uv.x);
    fragColor = vec4(r / 4.0);
}
