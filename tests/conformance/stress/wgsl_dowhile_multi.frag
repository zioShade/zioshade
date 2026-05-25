// Tests: do-while with multiple conditions
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_val;

void main() {
    float x = u_val;
    int iter = 0;
    do {
        x = x * x + 0.1;
        iter++;
    } while (x < 2.0 && iter < 30);
    fragColor = vec4(fract(x), float(iter) / 30.0, 0.0, 1.0);
}
