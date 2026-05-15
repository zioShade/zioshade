#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // 2D rotation matrix
    float angle = uv.x * 6.28318530;
    float c = cos(angle);
    float s = sin(angle);
    mat2 rot = mat2(c, -s, s, c);
    vec2 rotated = rot * (uv - vec2(0.5)) + vec2(0.5);
    float pattern = fract(rotated.x * 10.0);
    fragColor = vec4(pattern, pattern * 0.5, 1.0 - pattern, 1.0);
}
