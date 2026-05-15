#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Diamond pattern
    vec2 p = abs(uv - vec2(0.5)) * 2.0;
    float d = p.x + p.y;
    float edge = smoothstep(0.9, 1.0, d);
    fragColor = vec4(1.0 - edge, 0.5 - edge * 0.5, edge, 1.0);
}
