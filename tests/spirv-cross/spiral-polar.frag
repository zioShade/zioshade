#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Polar coordinates and spiral pattern using atan2
    vec2 centered = uv - 0.5;
    float angle = atan(centered.y, centered.x);
    float radius = length(centered);
    float spiral = sin(angle * 3.0 + radius * 20.0) * 0.5 + 0.5;
    float fade = smoothstep(0.5, 0.0, radius);

    fragColor = vec4(vec3(spiral * fade), 1.0);
}
