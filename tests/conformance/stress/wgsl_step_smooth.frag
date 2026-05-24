// Tests: step and smoothstep functions
#version 450
uniform float u_val;

void main() {
    float s1 = step(0.5, u_val);
    float s2 = smoothstep(0.2, 0.8, u_val);
    float r = s1 * 0.5 + s2 * 0.5;
    gl_FragColor = vec4(r, s1, s2, 1.0);
}
