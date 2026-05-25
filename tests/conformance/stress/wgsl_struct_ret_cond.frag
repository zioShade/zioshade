// Tests: function returning struct with nested fields
#version 450
layout(location = 0) out vec4 fragColor;

struct MatSample {
    vec3 albedo;
    float roughness;
    float metallic;
};

MatSample sampleMaterial(int id) {
    if (id == 0) {
        MatSample m;
        m.albedo = vec3(0.8, 0.2, 0.1);
        m.roughness = 0.3;
        m.metallic = 0.0;
        return m;
    } else {
        MatSample m;
        m.albedo = vec3(0.1, 0.3, 0.9);
        m.roughness = 0.7;
        m.metallic = 1.0;
        return m;
    }
}

void main() {
    MatSample s0 = sampleMaterial(0);
    MatSample s1 = sampleMaterial(1);
    vec3 color = mix(s0.albedo, s1.albedo, 0.5);
    float prop = s0.roughness + s1.metallic;
    fragColor = vec4(color * prop, 1.0);
}
