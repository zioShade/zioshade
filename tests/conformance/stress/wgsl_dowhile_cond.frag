// Tests: do-while loop with conditional body
#version 450
uniform float u_val;

void main() {
    float x = u_val;
    int iterations = 0;
    do {
        x = x * 0.5 + 0.1;
        iterations++;
    } while (x > 0.01 && iterations < 20);
    gl_FragColor = vec4(x, float(iterations) / 20.0, 0.0, 1.0);
}
