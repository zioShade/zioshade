#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

struct Light {
    vec3 pos;
    float intensity;
    vec3 color;
};

void main() {
    Light lights[3];
    lights[0] = Light(vec3(1.0, 0.0, 0.0), 0.8, vec3(1.0, 0.5, 0.2));
    lights[1] = Light(vec3(0.0, 1.0, 0.0), 0.6, vec3(0.2, 1.0, 0.5));
    lights[2] = Light(vec3(0.0, 0.0, 1.0), 0.4, vec3(0.5, 0.2, 1.0));

    vec3 total = vec3(0.0);
    for (int i = 0; i < 3; i++) {
        float dist = distance(lights[i].pos, vec3(uv, 0.0));
        float atten = lights[i].intensity / (1.0 + dist * dist);
        total += lights[i].color * atten;
    }
    fragColor = vec4(total, 1.0);
}
