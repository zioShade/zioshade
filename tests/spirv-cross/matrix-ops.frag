#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test matrix operations
    mat2 m = mat2(1.0, 2.0, 3.0, 4.0);
    vec2 v = m * uv;
    mat2 t = transpose(m);
    float d = determinant(m);
    mat2 inv = inverse(m);
    vec2 v2 = inv * v;
    fragColor = vec4(v, v2) * 0.25;
}
