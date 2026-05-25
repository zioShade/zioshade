// Tests: loop with step and multiple variables
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float x = 0.0;
    float y = 1.0;
    float z = 0.0;
    for (int i = 0; i < 20; i += 2) {
        x += float(i) * 0.01;
        y *= 0.95;
        z = x + y;
    }
    fragColor = vec4(fract(x), fract(y), fract(z), 1.0);
}
