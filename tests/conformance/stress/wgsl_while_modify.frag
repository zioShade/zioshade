// Tests: while loop with modification inside conditional
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float x = 1.0;
    int i = 0;
    while (x > 0.01) {
        x *= 0.8;
        i++;
        if (i > 100) break;
        if (x < 0.1) {
            x *= 1.5;  // bounce back up
        }
    }
    fragColor = vec4(vec3(fract(x)), float(i) / 100.0, 1.0);
}
