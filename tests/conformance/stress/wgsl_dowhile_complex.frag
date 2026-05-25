// Tests: do-while loop with complex condition
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float x = 0.0;
    int iter = 0;
    do {
        x = x * x + 0.25;
        iter++;
    } while (x < 2.0 && iter < 20);

    fragColor = vec4(vec3(fract(x)), float(iter) / 20.0, 1.0);
}
