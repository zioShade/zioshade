#version 450

layout(location = 0) in vec3 normal;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test normalize, reflect, dot
    vec3 n = normalize(normal);
    vec3 light_dir = normalize(vec3(1.0, 1.0, 1.0));
    float diffuse = max(dot(n, light_dir), 0.0);
    vec3 view_dir = vec3(0.0, 0.0, 1.0);
    vec3 refl = reflect(-light_dir, n);
    float spec = pow(max(dot(refl, view_dir), 0.0), 32.0);
    vec3 color = vec3(0.2) + vec3(0.8) * diffuse + vec3(1.0) * spec;
    fragColor = vec4(color, 1.0);
}
