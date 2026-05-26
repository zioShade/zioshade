// Test: complex struct with nested arrays and functions
#version 450

layout(location = 0) out vec4 fragColor;

struct Material {
    vec3 albedo;
    float roughness;
    float metallic;
    float ao;
};

struct PointLight {
    vec3 position;
    vec3 color;
    float radius;
};

vec3 computeLighting(Material mat, PointLight light, vec3 normal, vec3 fragPos, vec3 viewDir) {
    vec3 lightDir = normalize(light.position - fragPos);
    vec3 halfway = normalize(lightDir + viewDir);
    
    float dist = length(light.position - fragPos);
    float attenuation = 1.0 / (1.0 + (dist / light.radius) * (dist / light.radius));
    
    float diff = max(dot(normal, lightDir), 0.0);
    float spec = pow(max(dot(normal, halfway), 0.0), mix(16.0, 256.0, 1.0 - mat.roughness));
    
    vec3 diffuse = diff * light.color * attenuation;
    vec3 specular = spec * light.color * attenuation * (1.0 - mat.metallic);
    
    return (diffuse + specular) * mat.albedo + vec3(mat.ao * 0.03);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    Material mat;
    mat.albedo = vec3(0.8, 0.4, 0.2);
    mat.roughness = 0.5;
    mat.metallic = 0.3;
    mat.ao = 0.8;
    
    PointLight lights[2];
    lights[0].position = vec3(2.0, 3.0, 1.0);
    lights[0].color = vec3(1.0, 0.9, 0.8);
    lights[0].radius = 10.0;
    lights[1].position = vec3(-2.0, 1.0, 3.0);
    lights[1].color = vec3(0.5, 0.6, 1.0);
    lights[1].radius = 8.0;
    
    vec3 normal = normalize(vec3(0.0, 1.0, 0.0));
    vec3 fragPos = vec3(uv * 10.0, 0.0);
    vec3 viewDir = normalize(vec3(0.0, 0.0, 5.0) - fragPos);
    
    vec3 color = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        color += computeLighting(mat, lights[i], normal, fragPos, viewDir);
    }
    
    fragColor = vec4(color, 1.0);
}
