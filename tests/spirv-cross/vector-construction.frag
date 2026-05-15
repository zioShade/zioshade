#version 450

layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test vector construction from scalars and vectors
    float a = v_color.x;
    float b = v_color.y;
    vec2 ab = vec2(a, b);
    vec3 abc = vec3(ab, v_color.z);
    vec4 abcd = vec4(abc, v_color.w);
    fragColor = abcd;
}
