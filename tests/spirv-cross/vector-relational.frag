#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test vector relational builtins
    vec3 a = vec3(uv, 0.75);
    vec3 b = vec3(0.5);

    bvec3 lt = lessThan(a, b);
    bvec3 gt = greaterThan(a, b);
    bvec3 le = lessThanEqual(a, b);
    bvec3 ge = greaterThanEqual(a, b);
    bvec3 eq = equal(a, b);
    bvec3 ne = notEqual(a, b);

    float r = any(lt) ? 1.0 : 0.0;
    float g = all(gt) ? 1.0 : 0.0;
    float bl = any(ne) ? 1.0 : 0.0;

    fragColor = vec4(r, g, bl, 1.0);
}
