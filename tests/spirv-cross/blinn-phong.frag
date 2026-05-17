#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple vec3 operations chain
void main() {
    vec3 a = vec3(uv.x, uv.y, 0.5);
    
    // Chain of normalize/reflect operations
    vec3 n = normalize(a);
    vec3 light = normalize(vec3(1.0, 1.0, 1.0));
    vec3 view = normalize(vec3(0.0, 0.0, 1.0));
    
    // Diffuse
    float diff = max(dot(n, light), 0.0);
    
    // Specular (Blinn-Phong)
    vec3 half_vec = normalize(light + view);
    float spec = pow(max(dot(n, half_vec), 0.0), 32.0);
    
    // Fresnel approximation
    float fresnel = pow(1.0 - max(dot(n, view), 0.0), 5.0);
    
    vec3 col = vec3(0.1) + vec3(0.6, 0.3, 0.2) * diff + vec3(1.0) * spec * 0.5;
    col = mix(col, vec3(0.8, 0.9, 1.0), fresnel * 0.3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
