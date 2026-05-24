// Tests: recursive fibonacci-like pattern (non-recursive, iterative)
#version 450
uniform int u_n;

void main() {
    int a = 0;
    int b = 1;
    for (int i = 0; i < u_n; i++) {
        int temp = a + b;
        a = b;
        b = temp;
    }
    float result = float(a) / 1000.0;
    gl_FragColor = vec4(result, float(u_n) / 20.0, 0.0, 1.0);
}
