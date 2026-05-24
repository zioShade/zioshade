// Tests: complex expression with multiple operators
#version 450
uniform float u_a;
uniform float u_b;
uniform float u_c;

void main() {
    float d = (u_a + u_b) * u_c - (u_a * u_b + u_c);
    float e = d / (u_a + u_b + u_c + 0.001);
    float f = fract(e) * 2.0 - 1.0;
    gl_FragColor = vec4(f, abs(f), 1.0 - abs(f), 1.0);
}
