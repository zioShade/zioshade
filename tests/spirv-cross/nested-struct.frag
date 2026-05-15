#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

struct Material {
    vec3 albedo;
    float metallic;
    float roughness;
};

struct Surface {
    vec3 normal;
    float depth;
    Material mat;
};

void main()
{
    Surface s;
    s.normal = normalize(vec3(u, 1.0, u * 2.0));
    s.depth = u * 10.0;
    s.mat.albedo = vec3(0.8, 0.2, 0.1);
    s.mat.metallic = 0.5;
    s.mat.roughness = 0.3;

    float d = max(dot(s.normal, vec3(0.0, 1.0, 0.0)), 0.0);
    vec3 color = s.mat.albedo * (0.1 + 0.9 * d);
    fragColor = vec4(color, 1.0);
}
