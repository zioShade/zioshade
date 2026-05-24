// Tests: integer arithmetic and bitwise ops
#version 450
uniform int u_a;
uniform int u_b;

void main() {
    int sum = u_a + u_b;
    int diff = u_a - u_b;
    int prod = u_a * u_b;
    int band = u_a & u_b;
    int bor = u_a | u_b;
    int bxor = u_a ^ u_b;
    int shifted = u_a << 2;
    float r = float(sum % 256) / 255.0;
    float g = float(band & 0xFF) / 255.0;
    float b = float(bor & 0xFF) / 255.0;
    gl_FragColor = vec4(r, g, b, 1.0);
}
