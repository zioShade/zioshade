#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test vector relational functions
    vec4 a = vec4(u, u * 2.0, u * 3.0, 1.0);
    vec4 b = vec4(0.5, 1.0, 1.5, 1.0);
    bvec4 gt = greaterThan(a, b);
    bvec4 lt = lessThan(a, b);
    bvec4 eq = equal(a, b);
    float count = 0.0;
    if (gt.x) count += 1.0;
    if (gt.y) count += 1.0;
    if (gt.z) count += 1.0;
    if (gt.w) count += 1.0;
    fragColor = vec4(count / 4.0);
}
