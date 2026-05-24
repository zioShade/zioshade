// Tests: integer division and modulo
#version 450
uniform int u_a;
uniform int u_b;

void main() {
    int q = u_a / u_b;
    int r = u_a % u_b;
    float f = float(q) / 100.0 + float(r) / 10.0;
    gl_FragColor = vec4(f, 0.0, 0.0, 1.0);
}
