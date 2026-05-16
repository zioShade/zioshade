#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Reflect and refract
    vec3 incident = normalize(vec3(uv * 2.0 - 1.0, 1.0));
    vec3 normal = vec3(0.0, 0.0, 1.0);

    vec3 reflected = reflect(incident, normal);
    vec3 refracted = refract(incident, normal, 0.8);

    float r = reflected.x * 0.5 + 0.5;
    float g = refracted.y * 0.5 + 0.5;
    float b = dot(reflected, refracted) * 0.5 + 0.5;

    fragColor = vec4(r, g, b, 1.0);
}
