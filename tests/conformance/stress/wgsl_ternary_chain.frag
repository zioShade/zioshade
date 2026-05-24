// Tests: ternary chain with different types
#version 450
uniform float u_val;

void main() {
    float r = u_val > 0.66 ? 1.0 : (u_val > 0.33 ? 0.5 : 0.0);
    float g = 1.0 - r;
    gl_FragColor = vec4(r, g, u_val, 1.0);
}
