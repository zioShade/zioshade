// Tests: while loop (non-for)
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
    gl_FragColor = vec4(x, float(count) / 50.0, 0.0, 1.0);
}
