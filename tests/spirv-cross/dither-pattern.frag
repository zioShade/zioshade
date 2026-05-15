#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Dither pattern using step functions
    vec2 grid = floor(uv * 8.0);
    float pattern = step(0.5, fract(sin(dot(grid, vec2(12.9898, 78.233))) * 43758.5453));
    vec3 color = mix(vec3(0.2), vec3(0.8), pattern);
    fragColor = vec4(color, 1.0);
}
