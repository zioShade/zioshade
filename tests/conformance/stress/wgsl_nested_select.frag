// Tests: boolean select/ternary with nested conditions
#version 450
uniform float u_val;

void main() {
    float r = u_val > 0.5 ? 1.0 : 0.5;
    float g = u_val < 0.3 ? 0.0 : (u_val > 0.7 ? 1.0 : u_val);
    float b = u_val > 0.5 ? r : g;
    gl_FragColor = vec4(r, g, b, 1.0);
}
