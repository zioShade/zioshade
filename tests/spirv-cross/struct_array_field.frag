#version 310 es
precision highp float;
out vec4 fragColor;

struct Light {
    vec3 color;
    float intensity;
};

void main() {
    Light lights[3];
    for (int i = 0; i < 3; i++) {
        lights[i].color = vec3(float(i) * 0.3, 0.5, 1.0 - float(i) * 0.3);
        lights[i].intensity = float(i + 1) * 0.3;
    }
    vec3 col = vec3(0.0);
    for (int i = 0; i < 3; i++) {
        col += lights[i].color * lights[i].intensity;
    }
    fragColor = vec4(col, 1.0);
}
