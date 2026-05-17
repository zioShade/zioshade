#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test struct with functions
struct Light {
    vec3 pos;
    vec3 color;
    float intensity;
};

float attenuate(Light l, float dist) {
    return l.intensity / (1.0 + dist * dist);
}

vec3 shade(Light l, vec3 pos, vec3 normal) {
    vec3 to_light = l.pos - pos;
    float dist = length(to_light);
    vec3 light_dir = to_light / (dist + 0.001);
    float ndotl = max(dot(normal, light_dir), 0.0);
    return l.color * ndotl * attenuate(l, dist);
}

void main() {
    Light l1;
    l1.pos = vec3(0.5, 0.5, 1.0);
    l1.color = vec3(1.0, 0.9, 0.8);
    l1.intensity = 2.0;
    
    Light l2;
    l2.pos = vec3(0.8, 0.2, 0.5);
    l2.color = vec3(0.3, 0.5, 1.0);
    l2.intensity = 1.5;
    
    vec3 pos = vec3(uv, 0.0);
    vec3 normal = vec3(0.0, 0.0, 1.0);
    
    vec3 col = shade(l1, pos, normal) + shade(l2, pos, normal);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
