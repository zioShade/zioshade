// Tests: recursive-style accumulation with conditionals
#version 450
layout(location = 0) out vec4 fragColor;

float accumulate(float seed, int steps) {
    float val = seed;
    for (int i = 0; i < steps; i++) {
        val = val * 1.1 - 0.05;
        if (val > 2.0) val = val * 0.5;
        if (val < 0.0) val = -val;
    }
    return val;
}

void main() {
    float r = accumulate(0.5, 15);
    float g = accumulate(0.3, 10);
    float b = accumulate(0.7, 20);
    fragColor = vec4(fract(r), fract(g), fract(b), 1.0);
}
