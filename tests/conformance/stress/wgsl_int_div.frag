// Tests: integer division and modulo
#version 450
uniform int u_a;
uniform int u_b;

void main() {
    int q = u_a / u_b;
    int r = u_a % u_b;
    float fq = float(q) / 255.0;
    float fr = float(r) / 255.0;
    gl_FragColor = vec4(fq, fr, 0.0, 1.0);
}
