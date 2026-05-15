#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Concentric rings
    float d = length(uv - vec2(0.5));
    float ring = fract(d * 15.0);
    float edge = smoothstep(0.4, 0.5, ring) - smoothstep(0.5, 0.6, ring);
    vec3 color = mix(vec3(0.1, 0.1, 0.2), vec3(0.3, 0.6, 1.0), edge);
    fragColor = vec4(color, 1.0);
}
