// Tests: bvec comparison and mix
#version 450
uniform vec3 u_a;
uniform vec3 u_b;
uniform float u_thresh;

void main() {
    bvec3 mask = greaterThan(u_a, vec3(u_thresh));
    vec3 result = mix(u_b, u_a, mask);
    gl_FragColor = vec4(result, 1.0);
}
