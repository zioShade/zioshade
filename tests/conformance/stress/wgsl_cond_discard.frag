// Tests: discard with complex condition
#version 450
uniform float u_val;

void main() {
    if (u_val < 0.0 || u_val > 1.0) discard;
    float r = u_val * u_val;
    gl_FragColor = vec4(r, u_val, 1.0 - r, 1.0);
}
