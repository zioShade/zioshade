#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Procedural checkerboard
    float scale = 10.0;
    float cx = floor(uv.x * scale);
    float cy = floor(uv.y * scale);
    float checker = mod(cx + cy, 2.0);
    vec3 color = mix(vec3(0.1, 0.1, 0.1), vec3(0.9, 0.9, 0.9), checker);
    fragColor = vec4(color, 1.0);
}
