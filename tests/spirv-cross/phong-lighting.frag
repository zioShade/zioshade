#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Phong lighting model - exercises struct, functions, dot products
struct Light {
    vec3 position;
    vec3 color;
    float intensity;
};

vec3 computeLighting(vec3 normal, vec3 fragPos, vec3 viewDir, Light light) {
    vec3 lightDir = normalize(light.position - fragPos);
    
    // Diffuse
    float diff = max(dot(normal, lightDir), 0.0);
    vec3 diffuse = diff * light.color * light.intensity;
    
    // Specular
    vec3 reflectDir = reflect(-lightDir, normal);
    float spec = pow(max(dot(viewDir, reflectDir), 0.0), 32.0);
    vec3 specular = spec * light.color * light.intensity;
    
    return diffuse + specular;
}

void main() {
    vec3 normal = normalize(vec3(uv, 0.5));
    vec3 fragPos = vec3(uv * 2.0 - 1.0, 0.0);
    vec3 viewDir = normalize(-fragPos);
    
    Light l1;
    l1.position = vec3(1.0, 1.0, 2.0);
    l1.color = vec3(1.0, 0.9, 0.8);
    l1.intensity = 0.8;
    
    Light l2;
    l2.position = vec3(-1.0, -0.5, 1.0);
    l2.color = vec3(0.3, 0.4, 0.8);
    l2.intensity = 0.5;
    
    vec3 ambient = vec3(0.1);
    vec3 result = ambient + computeLighting(normal, fragPos, viewDir, l1) + computeLighting(normal, fragPos, viewDir, l2);
    
    fragColor = vec4(result, 1.0);
}
