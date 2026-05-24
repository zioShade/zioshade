// Tests: complex boolean logic
#version 450
uniform float u_a;
uniform float u_b;
uniform float u_c;

void main() {
    bool cond1 = u_a > 0.5;
    bool cond2 = u_b < 0.3;
    bool cond3 = u_c > 0.7;
    bool any_true = cond1 || cond2 || cond3;
    bool all_true = cond1 && cond2 && cond3;
    float r = any_true ? 1.0 : 0.0;
    float g = all_true ? 1.0 : 0.0;
    gl_FragColor = vec4(r, g, u_c, 1.0);
}
