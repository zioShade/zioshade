#version 310 es
precision highp float;
out vec4 fragColor;

int fib_iter(int n) {
    if (n <= 1) return n;
    int a = 0;
    int b = 1;
    for (int i = 2; i <= n; i++) {
        int temp = a + b;
        a = b;
        b = temp;
    }
    return b;
}

void main() {
    int n = int(mod(gl_FragCoord.x, 20.0));
    int f = fib_iter(n);
    fragColor = vec4(float(f) * 0.02);
}
