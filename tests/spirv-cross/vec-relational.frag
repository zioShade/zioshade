#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Vector relational operations
    vec3 a = vec3(uv.x, uv.y, uv.x * uv.y);
    vec3 b = vec3(0.3, 0.5, 0.7);

    bvec3 less = lessThan(a, b);
    bvec3 greater = greaterThan(a, b);
    bvec3 equal = equal(a, b);

    float r = less.x ? 1.0 : 0.0;
    float g = greater.y ? 1.0 : 0.0;
    float bl = equal.z ? 1.0 : 0.0;

    vec3 col = vec3(r, g, bl);
    fragColor = vec4(col, 1.0);
}
