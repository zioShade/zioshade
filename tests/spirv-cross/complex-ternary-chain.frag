#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Complex ternary chains with function calls
    float a = sin(uv.x * 3.0);
    float b = cos(uv.y * 2.0);
    float c = abs(a) > abs(b) ? a * a : b * b;
    float d = c > 0.0 ? sqrt(c) : -sqrt(-c);
    float e = d > 0.5 ? d * 2.0 : d * 0.5;
    fragColor = vec4(c * 0.5 + 0.5, d, e, 1.0);
}
