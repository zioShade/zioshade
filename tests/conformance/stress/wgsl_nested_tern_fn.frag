// Tests: nested ternary with function calls
#version 450
layout(location = 0) out vec4 fragColor;

float a(float x) { return x + 1.0; }
float b(float x) { return x * 2.0; }
float c(float x) { return x * x; }

void main() {
    float v = 0.5;
    float r = v > 0.3 ? a(v) : (v > 0.1 ? b(v) : c(v));
    fragColor = vec4(vec3(fract(r)), 1.0);
}
