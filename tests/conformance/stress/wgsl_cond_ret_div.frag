// Tests: conditional early return from function
#version 450
layout(location = 0) out vec4 fragColor;

float safeDivide(float a, float b) {
    if (abs(b) < 0.0001) return 0.0;
    return a / b;
}

void main() {
    float r = safeDivide(1.0, 0.5);
    float s = safeDivide(1.0, 0.0);
    fragColor = vec4(r, s, r + s, 1.0);
}
