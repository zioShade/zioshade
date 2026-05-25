// Tests: nested if-else with phi (multiple phi variables)
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float a = 0.3;
    float b = 0.7;
    float x;
    float y;
    if (a > 0.5) {
        if (b > 0.5) {
            x = a + b;
            y = a * b;
        } else {
            x = a - b;
            y = a / (b + 0.001);
        }
    } else {
        x = b - a;
        y = b * a;
    }
    fragColor = vec4(x, y, x + y, 1.0);
}
