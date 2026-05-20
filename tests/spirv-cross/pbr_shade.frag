#version 310 es
precision highp float;
out vec4 fragColor;

struct Material {
    vec3 albedo;
    float roughness;
    float metallic;
};

vec3 shade(vec3 normal, vec3 lightDir, Material mat) {
    float NdotL = max(dot(normal, lightDir), 0.0);
    vec3 diffuse = mat.albedo * NdotL * (1.0 - mat.metallic);
    vec3 halfDir = normalize(lightDir + vec3(0.0, 0.0, 1.0));
    float NdotH = max(dot(normal, halfDir), 0.0);
    float spec = pow(NdotH, mix(8.0, 256.0, 1.0 - mat.roughness));
    vec3 specular = vec3(spec) * mix(vec3(0.04), mat.albedo, mat.metallic);
    return diffuse + specular;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec3 normal = normalize(vec3(uv, sqrt(max(1.0 - dot(uv, uv), 0.0))));
    Material mat;
    mat.albedo = vec3(0.8, 0.2, 0.1);
    mat.roughness = 0.3;
    mat.metallic = 0.5;
    vec3 col = shade(normal, normalize(vec3(1.0, 1.0, 1.0)), mat);
    fragColor = vec4(col, 1.0);
}
