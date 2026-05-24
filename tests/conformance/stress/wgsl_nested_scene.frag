// Tests: nested structs with function parameter
#version 450
uniform float u_val;

struct Light {
    vec3 pos;
    vec3 color;
    float intensity;
};

struct Scene {
    Light lights[2];
    vec3 ambient;
};

vec3 shade(Light l, vec3 pos) {
    float d = distance(l.pos, pos);
    return l.color * l.intensity / (d + 1.0);
}

void main() {
    Scene s;
    s.lights[0].pos = vec3(1.0, 2.0, 3.0);
    s.lights[0].color = vec3(1.0, 0.9, 0.8);
    s.lights[0].intensity = 2.0;
    s.lights[1].pos = vec3(-1.0, 1.0, 2.0);
    s.lights[1].color = vec3(0.5, 0.6, 1.0);
    s.lights[1].intensity = 1.5;
    s.ambient = vec3(0.1);
    vec3 p = vec3(u_val, 0.0, u_val * 0.5);
    vec3 col = s.ambient;
    col += shade(s.lights[0], p);
    col += shade(s.lights[1], p);
    gl_FragColor = vec4(col, 1.0);
}
