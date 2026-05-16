#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

struct Light {
    vec3 position;
    vec3 color;
    float intensity;
};

vec3 computeLight(Light light, vec3 normal, vec3 fragPos) {
    vec3 lightDir = normalize(light.position - fragPos);
    float diff = max(dot(normal, lightDir), 0.0);
    return light.color * diff * light.intensity;
}

void main()
{
    // Struct-based lighting with multiple lights
    vec3 normal = normalize(vec3(uv.x, uv.y, 0.5));
    vec3 fragPos = vec3(uv, 0.0);

    Light l1;
    l1.position = vec3(1.0, 1.0, 1.0);
    l1.color = vec3(1.0, 0.8, 0.6);
    l1.intensity = 1.0;

    Light l2;
    l2.position = vec3(-1.0, 0.5, 0.5);
    l2.color = vec3(0.4, 0.6, 1.0);
    l2.intensity = 0.5;

    vec3 col = computeLight(l1, normal, fragPos) + computeLight(l2, normal, fragPos);
    fragColor = vec4(col, 1.0);
}
