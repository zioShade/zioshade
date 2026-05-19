#version 450

// Test: struct constructor-like pattern via init function
struct Material {
    vec3 albedo;
    float roughness;
    float metallic;
};

Material makeMaterial(vec3 color, float r, float m) {
    Material mat;
    mat.albedo = color;
    mat.roughness = clamp(r, 0.0, 1.0);
    mat.metallic = clamp(m, 0.0, 1.0);
    return mat;
}

vec3 evaluate(Material mat, vec3 lightDir, vec3 normal) {
    float diff = max(dot(normal, lightDir), 0.0);
    float spec = pow(diff, mix(8.0, 256.0, 1.0 - mat.roughness));
    return mat.albedo * (diff * 0.8 + 0.2) + spec * 0.3 * (1.0 - mat.metallic);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    Material m = makeMaterial(vec3(0.8, 0.6, 0.4), uv.x, uv.y);
    vec3 normal = normalize(vec3(0.0, 0.0, 1.0));
    vec3 lightDir = normalize(vec3(1.0, 1.0, 1.0));
    vec3 col = evaluate(m, lightDir, normal);
    gl_FragColor = vec4(col, 1.0);
}
