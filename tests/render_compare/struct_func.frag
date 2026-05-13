#version 430
layout(location = 0) out vec4 FragColor;
struct Material {
    vec3 albedo;
    float roughness;
    float metallic;
};
vec3 shade(Material mat, vec3 normal, vec3 lightDir) {
    float ndotl = max(dot(normal, lightDir), 0.0);
    vec3 diffuse = mat.albedo * ndotl;
    vec3 spec = vec3(pow(ndotl, 1.0 / max(mat.roughness, 0.01)));
    return mix(diffuse, spec, mat.metallic);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    Material m;
    m.albedo = vec3(0.8, 0.2, 0.1);
    m.roughness = 0.5;
    m.metallic = 0.3;
    vec3 n = normalize(vec3(uv - 0.5, 0.5));
    vec3 l = normalize(vec3(0.5, 0.8, 0.3));
    vec3 col = shade(m, n, l);
    FragColor = vec4(col, 1.0);
}
