// Test: phong shading with specular highlights
#version 450

layout(location = 0) in vec3 vNormal;
layout(location = 1) in vec3 vWorldPos;
layout(location = 2) in vec2 vUV;

layout(binding = 0) uniform UBO {
    vec3 lightPos;
    vec3 viewPos;
    vec3 lightColor;
    float shininess;
};

layout(location = 0) out vec4 fragColor;

void main() {
    vec3 norm = normalize(vNormal);
    vec3 lightDir = normalize(lightPos - vWorldPos);
    vec3 viewDir = normalize(viewPos - vWorldPos);
    vec3 halfway = normalize(lightDir + viewDir);
    
    // Ambient
    vec3 ambient = 0.1 * lightColor;
    
    // Diffuse
    float diff = max(dot(norm, lightDir), 0.0);
    vec3 diffuse = diff * lightColor;
    
    // Specular (Blinn-Phong)
    float spec = pow(max(dot(norm, halfway), 0.0), shininess);
    vec3 specular = spec * lightColor;
    
    vec3 result = ambient + diffuse + specular;
    fragColor = vec4(result, 1.0);
}
