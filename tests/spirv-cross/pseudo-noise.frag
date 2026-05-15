#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Noise-like pattern using fract and sin
    float n = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
    vec3 color = mix(vec3(0.2, 0.3, 0.4), vec3(0.8, 0.9, 1.0), n);
    fragColor = vec4(color, 1.0);
}
