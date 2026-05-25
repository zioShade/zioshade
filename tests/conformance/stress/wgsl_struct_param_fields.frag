// Tests: struct parameter with field modification in functions
#version 450
layout(location = 0) out vec4 fragColor;

struct Light {
    vec3 pos;
    vec3 color;
    float intensity;
};

vec3 compute(Light l, vec3 surface_pos) {
    vec3 to_light = l.pos - surface_pos;
    float dist = length(to_light);
    float atten = l.intensity / (dist * dist + 0.01);
    return normalize(to_light) * l.color * atten;
}

void main() {
    Light l;
    l.pos = vec3(2.0, 3.0, 1.0);
    l.color = vec3(1.0, 0.9, 0.8);
    l.intensity = 5.0;

    vec3 sp = vec3(0.0, 0.0, 0.0);
    vec3 c = compute(l, sp);
    fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
