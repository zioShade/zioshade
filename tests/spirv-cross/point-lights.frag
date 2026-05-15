#version 450

layout(location = 0) in vec3 v_normal;
layout(location = 0) out vec4 fragColor;

struct PointLight {
    vec3 position;
    vec3 color;
    float intensity;
};

vec3 computeLighting(PointLight light, vec3 normal, vec3 fragPos) {
    vec3 lightDir = normalize(light.position - fragPos);
    float diff = max(dot(normal, lightDir), 0.0);
    float dist = length(light.position - fragPos);
    float atten = light.intensity / (1.0 + 0.1 * dist * dist);
    return light.color * diff * atten;
}

void main()
{
    PointLight lights[2];
    lights[0].position = vec3(2.0, 2.0, 2.0);
    lights[0].color = vec3(1.0, 0.9, 0.8);
    lights[0].intensity = 5.0;
    lights[1].position = vec3(-2.0, 1.0, 0.0);
    lights[1].color = vec3(0.3, 0.4, 1.0);
    lights[1].intensity = 3.0;

    vec3 normal = normalize(v_normal);
    vec3 color = vec3(0.05);
    for (int i = 0; i < 2; i++) {
        color += computeLighting(lights[i], normal, vec3(0.0));
    }
    fragColor = vec4(color, 1.0);
}
