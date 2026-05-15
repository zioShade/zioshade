#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

struct Light {
    vec3 position;
    float intensity;
    vec3 color;
};

void main()
{
    Light l;
    l.position = vec3(u, u * 2.0, u * 3.0);
    l.intensity = u * 4.0;
    l.color = vec3(1.0, 0.5, 0.25);
    float d = length(l.position);
    vec3 result = l.color * l.intensity / max(d, 0.001);
    fragColor = vec4(result, 1.0);
}
