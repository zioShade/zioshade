#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test PBR-like shading
void main() {
    vec3 albedo = vec3(0.8, 0.2, 0.1);
    float metallic = uv.x;
    float roughness = uv.y;
    
    vec3 normal = normalize(vec3(uv, 0.5));
    vec3 light = normalize(vec3(1.0, 1.0, 0.5));
    vec3 view = vec3(0.0, 0.0, 1.0);
    
    float NdotL = max(dot(normal, light), 0.0);
    vec3 half_vec = normalize(light + view);
    float NdotH = max(dot(normal, half_vec), 0.0);
    
    // Simplified PBR
    float alpha = roughness * roughness;
    float spec = pow(NdotH, 2.0 / (alpha * alpha + 0.001) - 2.0);
    spec = clamp(spec, 0.0, 1.0);
    
    vec3 diffuse = albedo * (1.0 - metallic) * NdotL;
    vec3 specular = mix(vec3(0.04), albedo, metallic) * spec;
    
    vec3 col = diffuse + specular;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
