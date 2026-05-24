// Tests: do-while loop with float condition
#version 450
uniform float u_val;

void main() {
    float x = u_val;
    int i = 0;
    do {
        x = x * 0.95 + 0.01;
        i++;
    } while (x < 0.9 && i < 20);
    gl_FragColor = vec4(x, float(i) / 20.0, 0.0, 1.0);
}
