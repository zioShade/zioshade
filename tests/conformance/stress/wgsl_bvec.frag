// Tests: bvec and logical operations
#version 450
uniform vec3 u_a;
uniform vec3 u_b;

void main() {
    bvec3 eq = equal(u_a, u_b);
    bvec3 gt = greaterThan(u_a, u_b);
    bool any_eq = any(eq);
    bool all_gt = all(gt);
    float r = any_eq ? 1.0 : 0.0;
    float g = all_gt ? 1.0 : 0.0;
    gl_FragColor = vec4(r, g, 0.0, 1.0);
}
