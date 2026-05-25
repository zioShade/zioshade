// Tests: bvec comparison and selection
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 a = vec3(0.5, 0.3, 0.8);
    vec3 b = vec3(0.4, 0.6, 0.7);
    bvec3 cmp = greaterThan(a, b);
    vec3 sel = vec3(0.0);
    if (cmp.x) sel.x = 1.0;
    if (cmp.y) sel.y = 1.0;
    if (cmp.z) sel.z = 1.0;
    fragColor = vec4(sel, 1.0);
}
