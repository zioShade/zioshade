#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Repeated pattern using fract and distance
    vec2 grid = fract(uv * 5.0) - 0.5;
    float d = length(grid);
    float circle = smoothstep(0.3, 0.28, d);

    vec2 grid2 = fract(uv * 3.0 + 0.5) - 0.5;
    float d2 = length(grid2);
    float ring = abs(d2 - 0.3);
    float ringVal = smoothstep(0.05, 0.03, ring);

    fragColor = vec4(circle, ringVal, circle * ringVal, 1.0);
}
