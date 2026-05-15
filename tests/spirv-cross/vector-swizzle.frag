#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test vector swizzle and composite operations
    vec4 v = vec4(u, u * 2.0, u * 3.0, 1.0);
    vec2 xy = v.xy;
    vec2 zw = v.zw;
    float sum = xy.x + xy.y + zw.x + zw.y;
    fragColor = vec4(sum, sum, sum, 1.0);
}
