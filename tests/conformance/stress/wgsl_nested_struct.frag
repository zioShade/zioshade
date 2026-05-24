// Tests: nested structs with member access
#version 450
uniform float u_val;

struct Light {
    vec3 pos;
    vec3 color;
    float intensity;
};

struct Scene {
    Light lights[2];
    float ambient;
};

void main() {
    Scene s;
    s.ambient = 0.1;
    s.lights[0].pos = vec3(1.0, 2.0, 3.0);
    s.lights[0].color = vec3(1.0, 0.5, 0.0);
    s.lights[0].intensity = 2.0;
    s.lights[1].pos = vec3(-1.0, 0.0, 1.0);
    s.lights[1].color = vec3(0.0, 0.5, 1.0);
    s.lights[1].intensity = 1.5;

    vec3 col = vec3(s.ambient);
    for (int i = 0; i < 2; i++) {
        float dist = length(s.lights[i].pos);
        float atten = s.lights[i].intensity / (dist * dist);
        col += s.lights[i].color * atten;
    }
    gl_FragColor = vec4(col, 1.0);
}
