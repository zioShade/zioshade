#version 310 es
precision highp float;
out vec4 fragColor;

bvec3 test(vec3 v) {
    return bvec3(v.x > 0.5, v.y > 0.5, v.z > 0.5);
}

void main() {
    vec3 v = vec3(0.3, 0.7, 0.5);
    bvec3 b = test(v);
    bool any_true = any(b);
    bool all_true = all(b);
    float r = any_true ? 1.0 : 0.0;
    float g = all_true ? 1.0 : 0.0;
    float bl = b.x ? 0.5 : 0.2;
    fragColor = vec4(r, g, bl, 1.0);
}
