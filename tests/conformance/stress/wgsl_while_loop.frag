// Tests: while loop with early exit
#version 450
uniform float u_val;

void main() {
    float x = u_val;
    int count = 0;
    while (x > 0.01) {
        x *= 0.9;
        count++;
        if (count > 50) break;
    }
    float result = x + float(count) * 0.01;
    gl_FragColor = vec4(result, 0.0, 0.0, 1.0);
}
