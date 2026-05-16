#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Distance-based glow effect using atan2
    vec2 p = uv - 0.5;
    float angle = atan(p.y, p.x);
    float dist = length(p);

    float glow = 0.05 / (dist + 0.01);
    float color_angle = angle / 6.28318 + 0.5;

    float r = glow * (0.5 + 0.5 * sin(color_angle * 6.28318));
    float g = glow * (0.5 + 0.5 * sin(color_angle * 6.28318 + 2.094));
    float b = glow * (0.5 + 0.5 * sin(color_angle * 6.28318 + 4.189));

    fragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
}
