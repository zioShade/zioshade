#version 450

layout(location = 0) in vec3 normal;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Cross product and normalize
    vec3 tangent = normalize(cross(normal, vec3(0.0, 1.0, 0.0)));
    vec3 bitangent = cross(normal, tangent);
    float d = dot(tangent, bitangent);
    fragColor = vec4(tangent * 0.5 + 0.5, abs(d));
}
