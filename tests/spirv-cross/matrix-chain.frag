#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test matrix multiplication chain
    mat2 a = mat2(cos(uv.x), sin(uv.x), -sin(uv.x), cos(uv.x));
    mat2 b = mat2(1.0, uv.y, 0.0, 1.0);
    mat2 c = a * b;
    vec2 result = c * uv;
    fragColor = vec4(result, 0.0, 1.0);
}
