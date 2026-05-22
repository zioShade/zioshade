// Tests: struct constructor syntax with all-member initialization
precision mediump float;
uniform vec2 u_resolution;

struct Material {
    vec3 baseColor;
    float metallic;
    float roughness;
};

vec3 shade(Material m, vec3 normal, vec3 lightDir) {
    float NdotL = max(dot(normal, lightDir), 0.0);
    vec3 diffuse = m.baseColor * (1.0 - m.metallic) * NdotL;
    vec3 specular = vec3(pow(NdotL, 1.0 / (m.roughness + 0.01)));
    return diffuse + specular * m.metallic;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Construct struct using constructor syntax
    Material m = Material(vec3(0.8, 0.2, 0.1), 0.5, 0.3);
    
    vec3 normal = normalize(vec3(uv - 0.5, 0.5));
    vec3 lightDir = normalize(vec3(1.0, 1.0, 1.0));
    
    vec3 col = shade(m, normal, lightDir);
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
