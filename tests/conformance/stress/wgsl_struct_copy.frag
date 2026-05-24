#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test struct copy and modification
struct Light {
    vec3 position;
    vec3 color;
    float intensity;
};

Light makeLight(vec3 pos, vec3 col, float i) {
    Light l;
    l.position = pos;
    l.color = col;
    l.intensity = i;
    return l;
}

void main() {
    Light l1 = makeLight(vec3(1.0, 2.0, 3.0), vec3(1.0, 0.5, 0.0), 2.0);
    Light l2 = l1;
    l2.position = vec3(-1.0, 0.0, 1.0);
    l2.color = vec3(0.0, 0.5, 1.0);

    float d1 = distance(uv, l1.position.xy);
    float d2 = distance(uv, l2.position.xy);
    vec3 c = l1.color * (l1.intensity / (d1 + 1.0)) +
             l2.color * (l2.intensity / (d2 + 1.0));
    fragColor = vec4(c, 1.0);
}
