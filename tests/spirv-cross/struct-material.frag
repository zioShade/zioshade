#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test struct member assignment patterns
struct Material {
    vec3 albedo;
    float roughness;
    float metallic;
};

vec3 shade(Material mat, vec3 normal, vec3 lightDir) {
    float NdotL = max(dot(normal, lightDir), 0.0);
    return mat.albedo * (NdotL * 0.8 + 0.2);
}

void main() {
    Material mat1;
    mat1.albedo = vec3(0.8, 0.2, 0.1);
    mat1.roughness = 0.5;
    mat1.metallic = 0.0;
    
    Material mat2;
    mat2.albedo = vec3(0.1, 0.3, 0.9);
    mat2.roughness = 0.2;
    mat2.metallic = 1.0;
    
    vec3 normal = normalize(vec3(uv, 0.5));
    vec3 light = normalize(vec3(1.0, 1.0, 1.0));
    
    float blend = uv.x;
    Material mixed;
    mixed.albedo = mix(mat1.albedo, mat2.albedo, blend);
    mixed.roughness = mix(mat1.roughness, mat2.roughness, blend);
    mixed.metallic = mix(mat1.metallic, mat2.metallic, blend);
    
    vec3 col = shade(mixed, normal, light);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
