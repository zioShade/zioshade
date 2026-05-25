// Tests: nested function with multiple return paths
#version 450
layout(location = 0) out vec4 fragColor;

float process(float x) {
    if (x > 1.0) return x * 0.5;
    if (x > 0.5) return x + 0.1;
    return x * x;
}

float chain(float x) {
    float a = process(x);
    float b = process(a);
    return b;
}

void main() {
    float r = chain(1.5);
    float g = chain(0.7);
    float b = chain(0.3);
    fragColor = vec4(fract(r), fract(g), fract(b), 1.0);
}
