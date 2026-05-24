// Tests: do-while loop pattern
#version 450
uniform float u_val;

void main() {
    float x = u_val;
    int count = 0;
    float sum = 0.0;
    do {
        sum += x;
        x *= 0.5;
        count++;
    } while (x > 0.01 && count < 10);
    gl_FragColor = vec4(sum, float(count), x, 1.0);
}
