// Tests: nested ternary operator
#version 450
uniform float u_val;

void main() {
    float r = u_val < 0.33 ? 0.0 : (u_val < 0.66 ? 0.5 : 1.0);
    gl_FragColor = vec4(r, u_val, 0.0, 1.0);
}
