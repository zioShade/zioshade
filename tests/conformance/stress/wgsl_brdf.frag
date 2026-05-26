// Test: isotropic BRDF with Fresnel
#version 450

layout(location = 0) out vec4 fragColor;

const float PI = 3.14159265;

float distributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}

float geometrySmith(float NdotV, float NdotL, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    float g1 = NdotV / (NdotV * (1.0 - k) + k);
    float g2 = NdotL / (NdotL * (1.0 - k) + k);
    return g1 * g2;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec3 N = normalize(vec3(0.0, 1.0, 0.0));
    vec3 V = normalize(vec3(uv * 2.0 - 1.0, 1.0));
    vec3 L = normalize(vec3(1.0, 1.0, 0.5));
    vec3 H = normalize(V + L);
    
    vec3 F0 = vec3(0.04);
    float roughness = 0.5;
    
    float NDF = distributionGGX(max(dot(N, H), 0.0), roughness);
    float G = geometrySmith(max(dot(N, V), 0.0), max(dot(N, L), 0.0), roughness);
    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
    
    vec3 kS = F;
    vec3 kD = (1.0 - kS);
    
    float NdotL = max(dot(N, L), 0.0);
    vec3 specular = (NDF * G * F) / (4.0 * max(dot(N, V), 0.0) * NdotL + 0.001);
    vec3 Lo = (kD / PI + specular) * vec3(1.0) * NdotL;
    
    fragColor = vec4(Lo, 1.0);
}
