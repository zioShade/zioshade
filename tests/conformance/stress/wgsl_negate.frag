// Tests: negate and complement operations
#version 450
uniform float u_f;
uniform int u_i;

void main() {
    float neg_f = -u_f;
    int neg_i = -u_i;
    int comp_i = ~u_i;
    float r = neg_f / 255.0;
    float g = float(neg_i + comp_i) / 255.0;
    gl_FragColor = vec4(r, g, 0.0, 1.0);
}
