#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Discard test
    float d = length(uv - vec2(0.5));
    if (d > 0.5) discard;
    float c = 1.0 - d * 2.0;
    fragColor = vec4(c, c, c, 1.0);
}
