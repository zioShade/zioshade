#version 450

// Test nested struct types and member access
struct Light {
    vec3 position;
    vec3 color;
    float intensity;
};

struct Material {
    vec3 albedo;
    float roughness;
    float metallic;
};

struct Scene {
    Light lights[2];
    Material mat;
    vec3 ambient;
};

vec3 shade(Scene s, vec3 pos) {
    vec3 result = s.ambient * s.mat.albedo;
    for (int i = 0; i < 2; i++) {
        float d = distance(pos, s.lights[i].position);
        float atten = s.lights[i].intensity / (1.0 + d * d);
        vec3 diff = max(dot(normalize(s.lights[i].position - pos), vec3(0.0, 1.0, 0.0)), 0.0);
        result += s.lights[i].color * diff * atten * s.mat.albedo;
    }
    return result;
}

void main() {
    Scene s;
    s.lights[0].position = vec3(2.0, 3.0, 1.0);
    s.lights[0].color = vec3(1.0, 0.9, 0.8);
    s.lights[0].intensity = 5.0;
    s.lights[1].position = vec3(-1.0, 2.0, 3.0);
    s.lights[1].color = vec3(0.3, 0.4, 1.0);
    s.lights[1].intensity = 3.0;
    s.mat.albedo = vec3(0.8, 0.6, 0.4);
    s.mat.roughness = 0.5;
    s.mat.metallic = 0.0;
    s.ambient = vec3(0.05, 0.05, 0.1);
    vec3 col = shade(s, vec3(0.0));
    gl_FragColor = vec4(col, 1.0);
}
