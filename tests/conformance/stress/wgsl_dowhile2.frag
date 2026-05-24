// Tests: do-while loop with condition at end
#version 450
uniform float u_val;

void main() {
    float x = u_val;
    int i = 0;
    do {
        x *= 0.95;
        i++;
    } while (x > 0.001 && i < 100);
    gl_FragColor = vec4(x, float(i) / 100.0, 0.0, 1.0);
}
