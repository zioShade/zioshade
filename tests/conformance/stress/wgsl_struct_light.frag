// Tests: struct with nested array and iteration
#version 450
uniform float u_val;

struct Light {
    vec3 pos;
    float intensity;
    vec3 color;
};

void main() {
    Light l;
    l.pos = vec3(u_val, u_val * 0.5, 0.0);
    l.intensity = 2.0;
    l.color = vec3(1.0, 0.8, 0.6);
    float d = length(l.pos);
    vec3 c = l.color * l.intensity / (d + 1.0);
    gl_FragColor = vec4(c, 1.0);
}
