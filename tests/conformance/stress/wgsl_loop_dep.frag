// Tests: chain of stores with loop-carried dependencies
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_init;

void main() {
    float a = u_init;
    float b = u_init * 0.5;
    float c = 0.0;
    for (int i = 0; i < 15; i++) {
        float new_a = a * 0.9 + b * 0.1;
        float new_b = a * 0.1 + b * 0.9;
        c += abs(new_a - new_b);
        a = new_a;
        b = new_b;
    }
    fragColor = vec4(fract(a), fract(b), fract(c), 1.0);
}
