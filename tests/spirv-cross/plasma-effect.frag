#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Plasma effect
    float v1 = sin(uv.x * 10.0);
    float v2 = sin(uv.y * 10.0);
    float v3 = sin((uv.x + uv.y) * 10.0);
    float v4 = sin(length(uv - vec2(0.5)) * 14.0);
    float v = (v1 + v2 + v3 + v4) * 0.25 + 0.5;
    vec3 color;
    color.r = sin(v * 3.14159) * 0.5 + 0.5;
    color.g = sin(v * 3.14159 + 2.094) * 0.5 + 0.5;
    color.b = sin(v * 3.14159 + 4.188) * 0.5 + 0.5;
    fragColor = vec4(color, 1.0);
}
